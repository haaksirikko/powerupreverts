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
ConVar tf_weapon_criticals;

DynamicHook dhook_CCaptureFlag_Think;
DynamicHook dhook_CCaptureFlag_PickUp;
DynamicHook dhook_CCaptureFlag_Drop;
DynamicHook dhook_CTFWeaponBaseMelee_DoMeleeDamage;
DynamicHook dhook_CTFSniperRifle_GetProjectileDamage;

DynamicDetour detour_CTFPlayer_StateEnterACTIVE;
DynamicDetour detour_CTFGameRules_SetupOnRoundStart;
DynamicDetour detour_CCaptureFlag_Capture;
DynamicDetour detour_CWeaponMedigun_GetOverHealBonus;
DynamicDetour detour_CCaptureZone_Capture;

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
	tf_weapon_criticals = FindConVar("tf_weapon_criticals");

	tf_powerup_mode.AddChangeHook(TogglePowerupReverts);

	GameData conf = new GameData("powerupreverts");
	if (conf == null) SetFailState("Failed to load powerupreverts gamedata");

	dhook_CCaptureFlag_Think = DynamicHook.FromConf(conf, "CCaptureFlag::Think");
	dhook_CCaptureFlag_PickUp = DynamicHook.FromConf(conf, "CCaptureFlag::PickUp");
	dhook_CCaptureFlag_Drop = DynamicHook.FromConf(conf, "CCaptureFlag::Drop");
	dhook_CTFWeaponBaseMelee_DoMeleeDamage = DynamicHook.FromConf(conf, "CTFWeaponBaseMelee::DoMeleeDamage");
	dhook_CTFSniperRifle_GetProjectileDamage = DynamicHook.FromConf(conf, "CTFSniperRifle::GetProjectileDamage");

	detour_CTFPlayer_StateEnterACTIVE = DynamicDetour.FromConf(conf, "CTFPlayer::StateEnterACTIVE");
	detour_CTFGameRules_SetupOnRoundStart = DynamicDetour.FromConf(conf, "CTFGameRules::SetupOnRoundStart");
	detour_CCaptureFlag_Capture = DynamicDetour.FromConf(conf, "CCaptureFlag::Capture");
	detour_CWeaponMedigun_GetOverHealBonus = DynamicDetour.FromConf(conf, "CWeaponMedigun::GetOverHealBonus");
	detour_CCaptureZone_Capture = DynamicDetour.FromConf(conf, "CCaptureZone::Capture");

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
	VALIDATE_HANDLE(dhook_CTFWeaponBaseMelee_DoMeleeDamage);
	VALIDATE_HANDLE(dhook_CTFSniperRifle_GetProjectileDamage);

	VALIDATE_HANDLE(detour_CTFPlayer_StateEnterACTIVE);
	VALIDATE_HANDLE(detour_CTFGameRules_SetupOnRoundStart);
	VALIDATE_HANDLE(detour_CCaptureFlag_Capture);
	VALIDATE_HANDLE(detour_CWeaponMedigun_GetOverHealBonus);
	VALIDATE_HANDLE(detour_CCaptureZone_Capture);

	detour_CTFPlayer_StateEnterACTIVE.Enable(Hook_Pre, DHookCallback_Ent_Pre);
	detour_CTFPlayer_StateEnterACTIVE.Enable(Hook_Post, DHookCallback_Ent_Post);
	detour_CTFGameRules_SetupOnRoundStart.Enable(Hook_Pre, DHookCallback_Address_Pre);
	detour_CTFGameRules_SetupOnRoundStart.Enable(Hook_Post, DHookCallback_Address_Post);
	detour_CCaptureFlag_Capture.Enable(Hook_Pre, DHookCallback_EntParams_Pre);
	detour_CCaptureFlag_Capture.Enable(Hook_Post, DHookCallback_EntParams_Post);
	detour_CWeaponMedigun_GetOverHealBonus.Enable(Hook_Pre, DetourCallback_CWeaponMedigun_GetOverHealBonus_Pre);
	detour_CCaptureZone_Capture.Enable(Hook_Pre, DHookCallback_EntParams_Pre);
	detour_CCaptureZone_Capture.Enable(Hook_Post, DHookCallback_EntParams_Post);

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

int frame;
public void OnGameFrame() {
	frame++;

	if (!IsRevertedPowerupMode()) return;

	for (int client = 1; client <= MaxClients; client++) {
		UpdateFreeRide(client);
	}

	if (frame & 6 == 0) {
		float curtime = GetGameTime();

		for (int client = 1; client <= MaxClients; client++) {
			int flag = players[client].flag;

			if (
				flag <= 0 ||
				!IsValidEntity(flag) ||
				!IsClientInGame(client) ||
				!IsPlayerAlive(client)
			) {
				players[client].flag = -1;
				continue;
			}

			float time = GetEntPropFloat(flag, Prop_Send, "m_flTimeToSetPoisonous") - curtime;
			if (time > 0.0)
			{
				int second = RoundToCeil(time);
				if (second != players[client].last_displayed_second) {
					players[client].last_displayed_second = second;

					ClearSyncHud(client, hudsync);

					char message[32];
					Format(message, sizeof(message), "Poison in %ds", second);

					SetHudTextParams(-1.0, 0.925, 1.1, 255, 255, 255, 255, 0, 0.0, 0.0, 0.0);
					ShowSyncHudText(client, hudsync, message);
				}
			}
			else
			{
				ClearSyncHud(client, hudsync);
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

		// Disable crits. TODO: add hidden no-crit attribute to all weapons instead
		tf_weapon_criticals.BoolValue = false;

		ZeroPowerupModeProp();
	}
}

public void OnClientPutInServer(int client) {
	SDKHook(client, SDKHook_OnTakeDamage, SDKHookCB_OnTakeDamage);
	SDKHook(client, SDKHook_OnTakeDamageAlive, SDKHookCB_OnTakeDamageAlive);
	SDKHook(client, SDKHook_OnTakeDamagePost, SDKHookCB_OnTakeDamagePost);
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

// Prevent powerupmode modifiers in ApplyOnDamageModifyRules
Action SDKHookCB_OnTakeDamage(
	int victim, int& attacker, int& inflictor, float& damage, int& damage_type,
	int& weapon, float damage_force[3], float damage_position[3], int damage_custom
) {
	ZeroPowerupModeProp();
	return Plugin_Continue;
}
// Reset it here for dominations etc
Action SDKHookCB_OnTakeDamageAlive(
	int victim, int& attacker, int& inflictor, float& damage, int& damage_type,
	int& weapon, float damage_force[3], float damage_position[3], int damage_custom
) {
	ResetPowerupModeProp();
	return Plugin_Continue;
}
void SDKHookCB_OnTakeDamagePost(
	int victim, int attacker, int inflictor, float damage, int damage_type,
	int weapon, float damage_force[3], float damage_position[3], int damage_custom
) {
	ZeroPowerupModeProp();
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

MRESReturn DHookCallback_Address_Pre(Address _this) {
	ResetPowerupModeProp();
	return MRES_Ignored;
}
MRESReturn DHookCallback_Address_Post(Address _this) {
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
	if (!IsClientInGame(client) || !IsPlayerAlive(client) ||
		TF2_GetPlayerClass(client) != TFClass_Medic) {
		ClearFreeRide(client);
		return;
	}

	int medigun = GetPlayerWeaponSlot(client, TFWeaponSlot_Secondary);
	if (medigun <= 0) {
		ClearFreeRide(client);
		return;
	}

	int patient = GetEntPropEnt(medigun, Prop_Send, "m_hHealingTarget");

	if (patient >= 1 && patient <= MaxClients &&
		IsClientInGame(patient) && IsPlayerAlive(patient) &&
		GetEntPropEnt(patient, Prop_Send, "m_hGrapplingHookTarget") > 0) {

		if (players[client].free_ride_patient != patient) {
			SetEntPropEnt(client, Prop_Send, "m_hGrapplingHookTarget", patient);
			TF2_AddCondition(client, TFCond_GrapplingHookSafeFall, TFCondDuration_Infinite);
			TF2_AddCondition(client, TFCond_GrapplingHookLatched, TFCondDuration_Infinite);
			players[client].free_ride_patient = patient;
		}
	} else {
		ClearFreeRide(client);
	}
}

