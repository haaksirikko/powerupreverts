#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <clientprefs>
#include <tf2>
#include <tf2_stocks>
#include <tf2utils>
#include <tf2attributes>
#include <dhooks>
#include <sourcescramble>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_NAME "Mannpower Reverts"
#define PLUGIN_DESC "Reverts various Mannpower nerfs"
#define PLUGIN_AUTHOR "haaksirikko"
#define PLUGIN_VERSION "0.1"
#define PLUGIN_URL "https://castaway.tf"

enum RuneTypes_t
{
	RUNE_NONE = -1,
	RUNE_STRENGTH,
	RUNE_HASTE,
	RUNE_REGEN,
	RUNE_RESIST,
	RUNE_VAMPIRE,
	RUNE_REFLECT,
	RUNE_PRECISION,
	RUNE_AGILITY,
	RUNE_KNOCKOUT,
	RUNE_KING,
	RUNE_PLAGUE,
	RUNE_SUPERNOVA,

	// ADD NEW RUNE TYPE HERE, DO NOT RE-ORDER

	RUNE_TYPES_MAX
};

public Plugin myinfo = {
	name = PLUGIN_NAME,
	description = PLUGIN_DESC,
	author = PLUGIN_AUTHOR,
	version = PLUGIN_VERSION,
	url = PLUGIN_URL
};

bool g_bPowerupRevertsEnabled;
int g_entMannpowerLogicEntity = -1;

ConVar sm_powerup_reverts_enable;

ConVar tf_max_health_boost;
ConVar tf_powerup_mode;
ConVar tf_powerup_mode_imbalance_consecutive_min_players;
ConVar tf_powerup_mode_dominant_multiplier;
ConVar tf_powerup_mode_killcount_timer_length;

DynamicHook dhook_CCaptureFlag_Think;
DynamicHook dhook_CCaptureFlag_PickUp;
DynamicHook dhook_CCaptureFlag_Drop;
DynamicHook dhook_CTFGameRules_PlayerKilled;
DynamicHook dhook_CTFGameRules_SetupOnRoundStart;
DynamicHook dhook_CTFGameRules_SetupOnRoundRunning;
DynamicHook dhook_CBaseObject_StartBuilding;
DynamicHook dhook_CBaseObject_CheckUpgradeOnHit;
DynamicHook dhook_CBaseObject_StartUpgrading;
DynamicHook dhook_CTFWeaponBaseMelee_DoMeleeDamage;
DynamicHook dhook_CTFSniperRifle_GetProjectileDamage;

DynamicDetour detour_CTFPlayer_StateEnterACTIVE;
DynamicDetour detour_CCaptureFlag_Capture;
DynamicDetour detour_CWeaponMedigun_GetOverHealBonus;
DynamicDetour detour_CCaptureZone_Capture;
DynamicDetour detour_CTFRadiusDamageInfo_CalculateFalloff;

Handle hudsync;

enum struct Player {
	int flag;
	int last_displayed_second;
	int free_ride_patient;
}
Player players[MAXPLAYERS+1];

MemoryPatch patch_HeavyGrappleJumpBoost;
bool g_bHeavyGrapplePatchEnabled;

public void OnPluginStart() {
	hudsync = CreateHudSynchronizer();

	sm_powerup_reverts_enable = CreateConVar("sm_powerup_reverts_enable", "1", "Toggle Mannpower Reverts", _, true, 0.0, true, 1.0);
	sm_powerup_reverts_enable.AddChangeHook(TogglePowerupReverts);

	tf_max_health_boost = FindConVar("tf_max_health_boost");
	tf_powerup_mode = FindConVar("tf_powerup_mode");
	tf_powerup_mode_imbalance_consecutive_min_players = FindConVar("tf_powerup_mode_imbalance_consecutive_min_players");
	tf_powerup_mode_dominant_multiplier = FindConVar("tf_powerup_mode_dominant_multiplier");
	tf_powerup_mode_killcount_timer_length = FindConVar("tf_powerup_mode_killcount_timer_length");

	tf_powerup_mode.AddChangeHook(TogglePowerupReverts);

	HookEvent("post_inventory_application", Event_OnPostInventoryApplication, EventHookMode_Post);

	GameData conf = new GameData("powerupreverts");
	if (conf == null) SetFailState("Failed to load powerupreverts gamedata");

	dhook_CCaptureFlag_Think = DynamicHook.FromConf(conf, "CCaptureFlag::Think");
	dhook_CCaptureFlag_PickUp = DynamicHook.FromConf(conf, "CCaptureFlag::PickUp");
	dhook_CCaptureFlag_Drop = DynamicHook.FromConf(conf, "CCaptureFlag::Drop");
	dhook_CTFGameRules_PlayerKilled = DynamicHook.FromConf(conf, "CTFGameRules::PlayerKilled");
	dhook_CTFGameRules_SetupOnRoundStart = DynamicHook.FromConf(conf, "CTFGameRules::SetupOnRoundStart");
	dhook_CTFGameRules_SetupOnRoundRunning = DynamicHook.FromConf(conf, "CTFGameRules::SetupOnRoundRunning");
	dhook_CBaseObject_StartBuilding = DynamicHook.FromConf(conf, "CBaseObject::StartBuilding");
	dhook_CBaseObject_CheckUpgradeOnHit = DynamicHook.FromConf(conf, "CBaseObject::CheckUpgradeOnHit");
	dhook_CBaseObject_StartUpgrading = DynamicHook.FromConf(conf, "CBaseObject::StartUpgrading");
	dhook_CTFWeaponBaseMelee_DoMeleeDamage = DynamicHook.FromConf(conf, "CTFWeaponBaseMelee::DoMeleeDamage");
	dhook_CTFSniperRifle_GetProjectileDamage = DynamicHook.FromConf(conf, "CTFSniperRifle::GetProjectileDamage");

	detour_CTFPlayer_StateEnterACTIVE = DynamicDetour.FromConf(conf, "CTFPlayer::StateEnterACTIVE");
	detour_CCaptureFlag_Capture = DynamicDetour.FromConf(conf, "CCaptureFlag::Capture");
	detour_CWeaponMedigun_GetOverHealBonus = DynamicDetour.FromConf(conf, "CWeaponMedigun::GetOverHealBonus");
	detour_CCaptureZone_Capture = DynamicDetour.FromConf(conf, "CCaptureZone::Capture");
	detour_CTFRadiusDamageInfo_CalculateFalloff = DynamicDetour.FromConf(conf, "CTFRadiusDamageInfo::CalculateFalloff");

	patch_HeavyGrappleJumpBoost = MemoryPatch.CreateFromConf(conf, "CTFGameMovement::CheckJumpButton_HeavyGrappleJumpBoost");
	if (patch_HeavyGrappleJumpBoost == null || !patch_HeavyGrappleJumpBoost.Validate()) {
		LogError("Failed to create CTFGameMovement::CheckJumpButton_HeavyGrappleJumpBoost memory patch");
		patch_HeavyGrappleJumpBoost = null;
	}
	delete conf;

	#define VALIDATE_HANDLE(%1) if (%1 == null) SetFailState("Failed to hook " ... #%1)

	VALIDATE_HANDLE(dhook_CCaptureFlag_Think);
	VALIDATE_HANDLE(dhook_CCaptureFlag_PickUp);
	VALIDATE_HANDLE(dhook_CCaptureFlag_Drop);
	VALIDATE_HANDLE(dhook_CTFGameRules_PlayerKilled);
	VALIDATE_HANDLE(dhook_CTFGameRules_SetupOnRoundStart);
	VALIDATE_HANDLE(dhook_CTFGameRules_SetupOnRoundRunning);
	VALIDATE_HANDLE(dhook_CBaseObject_StartBuilding);
	VALIDATE_HANDLE(dhook_CBaseObject_CheckUpgradeOnHit);
	VALIDATE_HANDLE(dhook_CBaseObject_StartUpgrading);
	VALIDATE_HANDLE(dhook_CTFWeaponBaseMelee_DoMeleeDamage);
	VALIDATE_HANDLE(dhook_CTFSniperRifle_GetProjectileDamage);

	VALIDATE_HANDLE(detour_CTFPlayer_StateEnterACTIVE);
	VALIDATE_HANDLE(detour_CCaptureFlag_Capture);
	VALIDATE_HANDLE(detour_CWeaponMedigun_GetOverHealBonus);
	VALIDATE_HANDLE(detour_CCaptureZone_Capture);
	VALIDATE_HANDLE(detour_CTFRadiusDamageInfo_CalculateFalloff);

	detour_CTFPlayer_StateEnterACTIVE.Enable(Hook_Pre, DHookCallback_Ent_Pre);
	detour_CTFPlayer_StateEnterACTIVE.Enable(Hook_Post, DHookCallback_Ent_Post);
	detour_CCaptureFlag_Capture.Enable(Hook_Pre, DHookCallback_EntParams_Pre);
	detour_CCaptureFlag_Capture.Enable(Hook_Post, DHookCallback_EntParams_Post);
	detour_CWeaponMedigun_GetOverHealBonus.Enable(Hook_Pre, DetourCallback_CWeaponMedigun_GetOverHealBonus_Pre);
	detour_CCaptureZone_Capture.Enable(Hook_Pre, DHookCallback_EntParams_Pre);
	detour_CCaptureZone_Capture.Enable(Hook_Post, DHookCallback_EntParams_Post);
	detour_CTFRadiusDamageInfo_CalculateFalloff.Enable(Hook_Pre, DHookCallback_Address_Pre);
	detour_CTFRadiusDamageInfo_CalculateFalloff.Enable(Hook_Post, DHookCallback_Address_Post);

	for (int i = 1; i <= MaxClients; i++) {
		//if (IsClientConnected(i)) OnClientConnected(i);
		if (IsClientInGame(i)) OnClientPutInServer(i);
	}

	for (int i = MaxClients + 1; i < 2048; i++) {
		char class[64];
		if (IsValidEntity(i)) {
			GetEntityClassname(i, class, sizeof(class));
			OnEntityCreated(i, class);
		}
	}

	LogMessage(PLUGIN_NAME ... " has loaded.");
}

public void OnPluginEnd() {
	DisablePowerupReverts();
	LogMessage(PLUGIN_NAME ... " has unloaded.");
}

public void OnConfigsExecuted() {
	if (GameRules_GetProp("m_bPlayingMannVsMachine")) {
		LogMessage("Powerup mode is incompatible with MvM");
		DisablePowerupReverts();
		return;
	}

	int ent = -1;
	while ((ent = FindEntityByClassname(ent, "tf_logic_mannpower")) != -1) {
		LogMessage("Detected Mannpower logic entity");
		g_entMannpowerLogicEntity = ent;
		EnablePowerupReverts();

		dhook_CTFGameRules_PlayerKilled.HookGamerules(Hook_Pre, DHookCallback_AddressParams_Pre);
		dhook_CTFGameRules_PlayerKilled.HookGamerules(Hook_Post, DHookCallback_AddressParams_Post);
		dhook_CTFGameRules_SetupOnRoundStart.HookGamerules(Hook_Pre, DHookCallback_Address_Pre);
		dhook_CTFGameRules_SetupOnRoundStart.HookGamerules(Hook_Post, DHookCallback_Address_Post);
		dhook_CTFGameRules_SetupOnRoundRunning.HookGamerules(Hook_Pre, DHookCallback_Address_Pre);
		dhook_CTFGameRules_SetupOnRoundRunning.HookGamerules(Hook_Post, DHookCallback_Address_Post);
		return;
	}

	DisablePowerupReverts();
}

public void TogglePowerupReverts(ConVar convar, const char[] oldValue, const char[] newValue) {
	if (convar.BoolValue) {
		if (GameRules_GetProp("m_bPlayingMannVsMachine")) {
			LogMessage("Powerup mode is incompatible with MvM");
			DisablePowerupReverts();
			return;
		}

		if (g_entMannpowerLogicEntity != -1) {
			EnablePowerupReverts();
			return;
		} else {
			LogMessage("No Mannpower logic entity detected");		
		}
	}

	DisablePowerupReverts();
}

int frame;
public void OnGameFrame() {
	frame++;
	int client;

	if (!IsRevertedPowerupMode()) return;

	for (client = 1; client <= MaxClients; client++) {
		UpdateFreeRide(client);
	}

	if (frame & 6 == 0) {
		float curtime = GetGameTime();

		for (client = 1; client <= MaxClients; client++) {
			int flag = players[client].flag;

			if (
				flag <= 0 ||
				!IsValidEntity(flag) ||
				!IsClientInGame(client) ||
				!IsPlayerAlive(client) ||
				IsFakeClient(client) ||
				IsClientReplay(client) ||
				IsClientSourceTV(client)
			) {
				players[client].flag = -1;
				players[client].last_displayed_second = -1;
				continue;
			}

			float time = GetEntPropFloat(flag, Prop_Send, "m_flTimeToSetPoisonous") - curtime;
			if (time > 0.0)
			{
				int second = RoundToCeil(time);
				if (second != players[client].last_displayed_second) {
					players[client].last_displayed_second = second;

					char message[32];
					Format(message, sizeof(message), "Poison in %ds", second);

					SetHudTextParams(-1.0, 0.925, 1.1, 255, 255, 255, 255, 0, 0.0, 0.0, 0.0);
					ShowSyncHudText(client, hudsync, message);
				}
			}
			else
			{
				players[client].flag = -1;
				players[client].last_displayed_second = -1;
			}
		}
	}

	if (frame % 66 == 0) {
		// Set these to high values such that they practically never happen
		tf_powerup_mode_imbalance_consecutive_min_players.IntValue = 999;
		tf_powerup_mode_dominant_multiplier.IntValue = 999;
		tf_powerup_mode_killcount_timer_length.IntValue = 999;

		ZeroPowerupModeProp();
	}
}

public void OnClientPutInServer(int client) {
	SDKHook(client, SDKHook_OnTakeDamage, SDKHookCB_OnTakeDamage);
	SDKHook(client, SDKHook_Spawn, SDKHookCB_Spawn);
	SDKHook(client, SDKHook_SpawnPost, SDKHookCB_SpawnPost);
}

// Handles rune drop on disconnect
public void OnClientDisconnect(int client) {
	ResetPowerupModeProp();
	ClearFreeRide(client);
	players[client].flag = -1;
	players[client].last_displayed_second = -1;
}
public void OnClientDisconnect_Post(int client) {
	ZeroPowerupModeProp();
}

public void OnEntityCreated(int entity, const char[] class) {
	if (entity < 0 || entity >= 2048) return;

	if (StrContains(class, "obj_") == 0) {
		SDKHook(entity, SDKHook_OnTakeDamage, SDKHookCB_OnTakeDamage_Building);
		SDKHook(entity, SDKHook_OnTakeDamagePost, SDKHookCB_OnTakeDamagePost_Building);
		dhook_CBaseObject_StartBuilding.HookEntity(Hook_Pre, entity, DHookCallback_EntReturnParams_Pre);
		dhook_CBaseObject_StartBuilding.HookEntity(Hook_Post, entity, DHookCallback_EntReturnParams_Post);
		dhook_CBaseObject_CheckUpgradeOnHit.HookEntity(Hook_Pre, entity, DHookCallback_EntReturnParams_Pre);
		dhook_CBaseObject_CheckUpgradeOnHit.HookEntity(Hook_Post, entity, DHookCallback_EntReturnParams_Post);
		dhook_CBaseObject_StartUpgrading.HookEntity(Hook_Pre, entity, DHookCallback_Ent_Pre);
		dhook_CBaseObject_StartUpgrading.HookEntity(Hook_Post, entity, DHookCallback_Ent_Post);
	}
	else if (strncmp(class, "tf_weapon_sniperrifle", sizeof("tf_weapon_sniperrifle")) == 0) {
		dhook_CTFSniperRifle_GetProjectileDamage.HookEntity(Hook_Pre, entity, DHookCallback_EntReturn_Pre);
		dhook_CTFSniperRifle_GetProjectileDamage.HookEntity(Hook_Post, entity, DHookCallback_EntReturn_Post);
	}
	else if (StrEqual(class, "item_powerup_rune_temp")) {
		SDKHook(entity, SDKHook_Spawn, SDKHookCB_Spawn);
		SDKHook(entity, SDKHook_SpawnPost, SDKHookCB_SpawnPost);
	}
	else if (StrEqual(class, "item_teamflag")) {
		dhook_CCaptureFlag_Think.HookEntity(Hook_Pre, entity, DHookCallback_Ent_Pre);
		dhook_CCaptureFlag_Think.HookEntity(Hook_Post, entity, DHookCallback_Ent_Post);
		dhook_CCaptureFlag_PickUp.HookEntity(Hook_Pre, entity, DHookCallback_CCaptureFlag_PickUp_Pre);
		dhook_CCaptureFlag_PickUp.HookEntity(Hook_Post, entity, DHookCallback_EntParams_Post);
		dhook_CCaptureFlag_Drop.HookEntity(Hook_Pre, entity, DHookCallback_EntParams_Pre);
		dhook_CCaptureFlag_Drop.HookEntity(Hook_Post, entity, DHookCallback_CCaptureFlag_Drop_Post);
	}
}

public Action Event_OnPostInventoryApplication(Event event, const char[] name, bool dontBroadcast) {
	if (!IsRevertedPowerupMode()) return Plugin_Continue;

	int client = GetClientOfUserId(GetEventInt(event, "userid"));

	if (TF2_GetPlayerClass(client) == TFClass_Scout) {
		// no fall damage for scout
		// TODO: make this toggleable
		TF2Attrib_SetByName(client, "cancel falling damage", 1.0);
	}
	else {
		TF2Attrib_RemoveByName(client, "cancel falling damage");
	}

	int length = GetEntPropArraySize(client, Prop_Send, "m_hMyWeapons");
	for (int i = 0; i < length; i++)
	{
		int weapon = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", i);
		if (weapon != -1)
		{
			// disable crits
			TF2Attrib_SetByName(weapon, "crit mod disabled hidden", 0.0);
		}
	}
	
	return Plugin_Continue;
}

// Prevent powerupmode modifiers for damage
Action SDKHookCB_OnTakeDamage(
	int victim, int& attacker, int& inflictor, float& damage, int& damage_type,
	int& weapon, float damage_force[3], float damage_position[3], int damage_custom
) {
	ZeroPowerupModeProp();

	// Vampire heal on burn damage
	if (
		IsRevertedPowerupMode() &&
		damage_type == (DMG_BURN | DMG_PREVENT_PHYSICS_FORCE) &&
		victim >= 1 && victim <= MaxClients
	) {
		int provider = TF2Util_GetPlayerConditionProvider(victim, TFCond_OnFire);
		if (
			provider != victim &&
			provider >= 1 && provider <= MaxClients &&
			GetCarryingRuneType(provider) == RUNE_VAMPIRE
		) {
			TF2Util_TakeHealth(provider, damage, TAKEHEALTH_IGNORE_MAXHEALTH);	
		}
	}

	return Plugin_Continue;
}

// Building damage
Action SDKHookCB_OnTakeDamage_Building(
	int victim, int& attacker, int& inflictor, float& damage, int& damage_type,
	int& weapon, float damage_force[3], float damage_position[3], int damage_custom
) {
	ResetPowerupModeProp();
	return Plugin_Continue;
}
void SDKHookCB_OnTakeDamagePost_Building(
	int victim, int attacker, int inflictor, float damage, int damage_type,
	int weapon, float damage_force[3], float damage_position[3], int damage_custom
) {
	ZeroPowerupModeProp();
}

// Handles uber respawn and temp rune spawning
Action SDKHookCB_Spawn(int entity) {
	ResetPowerupModeProp();
	return Plugin_Continue;
}
void SDKHookCB_SpawnPost(int entity) {
	ZeroPowerupModeProp();

	if (entity >= 1 && entity <= MaxClients) {
		int weapon = GetPlayerWeaponSlot(entity, TFWeaponSlot_Melee);
		if (weapon > 0) {
			dhook_CTFWeaponBaseMelee_DoMeleeDamage.HookEntity(Hook_Pre, weapon, DHookCallback_EntParams_Pre);
			dhook_CTFWeaponBaseMelee_DoMeleeDamage.HookEntity(Hook_Post, weapon, DHookCallback_EntParams_Post);
		}
	}
}

// Poisonous flag
MRESReturn DHookCallback_CCaptureFlag_PickUp_Pre(int entity, DHookParam parameters) {
	ResetPowerupModeProp();

	int client = parameters.Get(1);
	if (client >= 1 && client <= MaxClients) {
		players[client].flag = entity;
	}
	return MRES_Ignored;
}
MRESReturn DHookCallback_CCaptureFlag_Drop_Post(int entity, DHookParam parameters) {
	ZeroPowerupModeProp();

	int client = parameters.Get(1);
	if (
		client >= 1 && client <= MaxClients &&
		players[client].flag == entity
	) {
		ClearSyncHud(client, hudsync);
		players[client].flag = -1;
		players[client].last_displayed_second = -1;
	}
	return MRES_Ignored;
}

MRESReturn DetourCallback_CWeaponMedigun_GetOverHealBonus_Pre(int entity, DHookReturn returnValue, DHookParam parameters) {
	if (IsRevertedPowerupMode()) {
		float flOverhealBonus = tf_max_health_boost.FloatValue - 1.0;
		float flMod = 1.0;
		flMod = TF2Attrib_HookValueFloat(flMod, "mult_medigun_overheal_amount", entity);
		int patient = parameters.Get(1);
		if (patient >= 1 && patient <= MaxClients) {
			flMod = TF2Attrib_HookValueFloat(flMod, "mult_patient_overheal_penalty", patient);

			int weapon = GetEntPropEnt(patient, Prop_Send, "m_hActiveWeapon");
			if (weapon > 0) {
				flMod = TF2Attrib_HookValueFloat(flMod, "mult_patient_overheal_penalty_active", weapon);
			}
		}

		if (flMod >= 1.0)
		{
			flOverhealBonus += flMod;
		}
		else if (flMod < 1.0 && flOverhealBonus > 0.0)
		{
			flOverhealBonus *= flMod;
			flOverhealBonus += 1.0;
		}

		// Safety net
		if (flOverhealBonus < 1.0)
		{
			flOverhealBonus = 1.0;
		}

		returnValue.Value = flOverhealBonus;
		return MRES_Override;
	}
	return MRES_Ignored;
}

// Generic callbacks so the plugin doesn't get bloated with a bajillion functions that do the same thing
MRESReturn DHookCallback_Ent_Pre(int client) {
	ResetPowerupModeProp();
	return MRES_Ignored;
}
MRESReturn DHookCallback_Ent_Post(int client) {
	ZeroPowerupModeProp();
	return MRES_Ignored;
}

MRESReturn DHookCallback_EntReturn_Pre(int entity, DHookReturn returnValue) {
	ResetPowerupModeProp();
	return MRES_Ignored;
}
MRESReturn DHookCallback_EntReturn_Post(int entity, DHookReturn returnValue) {
	ZeroPowerupModeProp();
	return MRES_Ignored;
}

MRESReturn DHookCallback_EntParams_Pre(int entity, DHookParam parameters) {
	ResetPowerupModeProp();
	return MRES_Ignored;
}
MRESReturn DHookCallback_EntParams_Post(int entity, DHookParam parameters) {
	ZeroPowerupModeProp();
	return MRES_Ignored;
}

MRESReturn DHookCallback_EntReturnParams_Pre(int entity, DHookReturn returnValue, DHookParam parameters) {
	ResetPowerupModeProp();
	return MRES_Ignored;
}
MRESReturn DHookCallback_EntReturnParams_Post(int entity, DHookReturn returnValue, DHookParam parameters) {
	ZeroPowerupModeProp();
	return MRES_Ignored;
}

MRESReturn DHookCallback_Address_Pre(Address _this) {
	ResetPowerupModeProp();
	return MRES_Ignored;
}
MRESReturn DHookCallback_Address_Post(Address _this) {
	ZeroPowerupModeProp();
	return MRES_Ignored;
}

MRESReturn DHookCallback_AddressParams_Pre(Address _this, DHookParam parameters) {
	ResetPowerupModeProp();
	return MRES_Ignored;
}
MRESReturn DHookCallback_AddressParams_Post(Address _this, DHookParam parameters) {
	ZeroPowerupModeProp();
	return MRES_Ignored;
}

void ResetPowerupModeProp(bool bypass = false) {
	if (!bypass && g_bPowerupRevertsEnabled == false) return;

	GameRules_SetProp("m_bPowerupMode", tf_powerup_mode.IntValue);
}

void ZeroPowerupModeProp(bool bypass = false) {
	if (!bypass && g_bPowerupRevertsEnabled == false) return;

	GameRules_SetProp("m_bPowerupMode", 0);
}

bool IsRevertedPowerupMode() {
	return tf_powerup_mode.BoolValue && g_bPowerupRevertsEnabled;
}

void EnablePowerupReverts() {
	g_bPowerupRevertsEnabled = sm_powerup_reverts_enable.BoolValue;
	if (g_bPowerupRevertsEnabled) {
		ZeroPowerupModeProp(true);
		ApplyHeavyGrappleJumpBoost(true);
		LogMessage("Mannpower Reverts enabled");
	} else {
		DisablePowerupReverts();
	}
}

void DisablePowerupReverts() {
	g_bPowerupRevertsEnabled = false;
	ResetPowerupModeProp(true);
	ApplyHeavyGrappleJumpBoost(false);
	for (int client = 1; client <= MaxClients; client++) {
		ClearFreeRide(client);
	}
	LogMessage("Mannpower Reverts disabled");
}

void ApplyHeavyGrappleJumpBoost(bool enable) {
	if (patch_HeavyGrappleJumpBoost == null) return;
	if (enable == g_bHeavyGrapplePatchEnabled) return;

	if (enable) {
		if (patch_HeavyGrappleJumpBoost.Enable()) {
			g_bHeavyGrapplePatchEnabled = true;
			LogMessage("Heavy grapple jump boost revert enabled");
		}
	} else {
		patch_HeavyGrappleJumpBoost.Disable();
		g_bHeavyGrapplePatchEnabled = false;
	}
}

void ClearFreeRide(int client) {
	if (players[client].free_ride_patient == 0) return;

	if (IsClientInGame(client)) {
		SetEntPropEnt(client, Prop_Send, "m_hGrapplingHookTarget", -1);
		TF2_RemoveCondition(client, TFCond_GrapplingHookSafeFall);
		TF2_RemoveCondition(client, TFCond_GrapplingHookLatched);
	}
	players[client].free_ride_patient = 0;
}

void UpdateFreeRide(int client) {
	if (
		!IsClientInGame(client) ||
		!IsPlayerAlive(client) ||
		TF2_GetPlayerClass(client) != TFClass_Medic
	) {
		ClearFreeRide(client);
		return;
	}

	int medigun = GetPlayerWeaponSlot(client, TFWeaponSlot_Secondary);
	if (medigun <= 0) {
		ClearFreeRide(client);
		return;
	}

	int patient = GetEntPropEnt(medigun, Prop_Send, "m_hHealingTarget");

	if (
		patient >= 1 && patient <= MaxClients &&
		IsClientInGame(patient) &&
		IsPlayerAlive(patient) &&
		GetEntPropEnt(patient, Prop_Send, "m_hGrapplingHookTarget") > 0
	) {

		if (players[client].free_ride_patient != patient) {
			SetEntPropEnt(client, Prop_Send, "m_hGrapplingHookTarget", patient);
			TF2_AddCondition(client, TFCond_GrapplingHookSafeFall);
			TF2_AddCondition(client, TFCond_GrapplingHookLatched);
			players[client].free_ride_patient = patient;
		}
	} else {
		ClearFreeRide(client);
	}
}

TFCond GetConditionFromRuneType(RuneTypes_t rune)
{
	switch (rune) { 
		case RUNE_NONE:			return view_as<TFCond>(-1);
		case RUNE_STRENGTH:		return TFCond_RuneStrength;
		case RUNE_HASTE:		return TFCond_RuneHaste;
		case RUNE_REGEN:		return TFCond_RuneRegen;
		case RUNE_RESIST:		return TFCond_RuneResist;
		case RUNE_VAMPIRE:		return TFCond_RuneVampire;
		case RUNE_REFLECT:		return TFCond_RuneWarlock;
		case RUNE_PRECISION:	return TFCond_RunePrecision;
		case RUNE_AGILITY:		return TFCond_RuneAgility;
		case RUNE_KNOCKOUT:		return TFCond_RuneKnockout;
		case RUNE_KING:			return TFCond_KingRune;
		case RUNE_PLAGUE:		return TFCond_PlagueRune;
		case RUNE_SUPERNOVA:	return TFCond_SupernovaRune;
		default: LogError("Unexpected rune_type rt (%d) in GetConditionFromRuneType", rune);	
	}

	return view_as<TFCond>(-1);
}

static RuneTypes_t GetCarryingRuneType(int client)
{
    RuneTypes_t rune = RUNE_NONE;
    for (RuneTypes_t i = view_as<RuneTypes_t>(0); i < RUNE_TYPES_MAX; ++i)
    {
        if (TF2_IsPlayerInCondition(client, GetConditionFromRuneType(i)))
        {
            rune = i;
            break;
        }
    }
    return rune;
}

