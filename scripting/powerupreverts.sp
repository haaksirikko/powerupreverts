#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
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
#define PLUGIN_VERSION "0.6"
#define PLUGIN_URL ""

#define MAX_ENTITIES 2048

// Powerup glow updates run every N game frames (~6.6 Hz at 66 tick)
#define GLOW_REFRESH_INTERVAL 10

// Supernova carriers reveal enemies within this distance (1500 units, squared)
#define GLOW_SUPERNOVA_RADIUS_SQR 2250000.0

// Low health carriers reveal themselves below this health ratio
#define GLOW_LOW_HEALTH_RATIO 0.3

// A glow with no eligible recipients is disabled at once but kept for this many
// refreshes (~0.6 s at 66 tick) before removal, so a carrier stepping behind cover
// does not rebuild the glow entity every refresh
#define GLOW_CULL_GRACE_REFRESHES 4

// Glow groups categorize different types of glow effects, which may have distinct propagation rules and visibility conditions.
enum GlowGroup {
	GLOW_GROUP_TEAM,
	GLOW_GROUP_SUPERNOVA,
	GLOW_GROUP_COUNT
};

// Glow routing determines how a glow effect is applied and propagated to observers.
enum GlowRoute {
	GLOW_ROUTE_FLAG,
	GLOW_ROUTE_SHARED_PLAYER,
	GLOW_ROUTE_DESTROYING
};

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
bool g_bDetoursEnabled;

ConVar sm_powerupreverts_enable;
ConVar sm_powerupreverts_crits;
ConVar sm_powerupreverts_dominant;
ConVar sm_powerupreverts_imbalance_swap;
ConVar sm_powerupreverts_powerup_glow;

ConVar tf_max_health_boost;
ConVar tf_powerup_mode;
ConVar tf_powerup_mode_imbalance_consecutive_min_players;
ConVar tf_powerup_mode_dominant_multiplier;

DynamicHook dhook_CAmmoPack_MyTouch;
DynamicHook dhook_CCaptureFlag_Think;
DynamicHook dhook_CCaptureFlag_PickUp;
DynamicHook dhook_CCaptureFlag_Drop;
DynamicHook dhook_CTFGameRules_FlPlayerFallDamage;
DynamicHook dhook_CTFGameRules_SetupOnRoundStart;
DynamicHook dhook_CTFGameRules_SetupOnRoundRunning;
DynamicHook dhook_CTFWeaponBase_PrimaryAttack;
DynamicHook dhook_CBaseObject_StartBuilding;
DynamicHook dhook_CBaseObject_CheckUpgradeOnHit;
DynamicHook dhook_CBaseObject_StartUpgrading;
DynamicHook dhook_CTFWeaponBaseMelee_DoMeleeDamage;
DynamicHook dhook_CTFSniperRifle_GetProjectileDamage;
DynamicHook dhook_CWeaponMedigun_GetHealRate;
DynamicHook dhook_CTFPlayer_EventKilled;
DynamicHook dhook_CTFGlow_UpdateTransmitState;

DynamicDetour detour_CTFPlayer_StateEnterACTIVE;
DynamicDetour detour_CCaptureFlag_Capture;
DynamicDetour detour_CWeaponMedigun_GetOverHealBonus;
DynamicDetour detour_CCaptureZone_Capture;
DynamicDetour detour_CTFRadiusDamageInfo_CalculateFalloff;
DynamicDetour detour_CObjectSapper_SapperThink;
DynamicDetour detour_CTFPlayerShared_ConditionThink;
DynamicDetour detour_CWeaponMedigun_FindAndHealTargets;
DynamicDetour detour_CTFPlayer_TFPlayerThink;
DynamicDetour detour_CTFAmmoPack_PackTouch;

MemoryPatch patch_HeavyGrappleJumpBoost;

Handle hudsync;

enum struct Player {
	int flag;
	int last_displayed_second;
	int free_ride_patient;
}
Player players[MAXPLAYERS+1];

// Restored Mannpower glow for a stolen intelligence (one tf_glow per flag entity)
enum struct FlagGlow {
	int glow;          // tf_glow entity, 0 = not created yet, -1 = creation failed
	bool enabled;      // whether the glow is currently enabled
}
FlagGlow flag_glows[MAX_ENTITIES];

// One glow per carrier and color group, shared by every eligible observer
enum struct SharedGlow {
	int glow;
	int color;
	bool observers[MAXPLAYERS + 1];
	bool desired_observers[MAXPLAYERS + 1];
	char idle;	// consecutive refreshes without an eligible recipient
}
SharedGlow player_glows[MAXPLAYERS + 1][GLOW_GROUP_COUNT];

enum struct GlowEntity {
	int target;
	GlowRoute route;
	GlowGroup group;
}
GlowEntity glow_entities[MAX_ENTITIES];

public void OnPluginStart() {
	hudsync = CreateHudSynchronizer();

	char desc[] = "Toggle Mannpower Reverts\n 0: Disable\n 1: Enable, powerup carriers have vanilla penalties\n 2: Enable, powerup carriers have no penalties";
	sm_powerupreverts_enable = CreateConVar("sm_powerupreverts_enable", "1", desc, _, true, 0.0, true, 2.0);
	sm_powerupreverts_crits = CreateConVar("sm_powerupreverts_crits", "0", "Enable crits in Mannpower", _, true, 0.0, true, 1.0);
	sm_powerupreverts_dominant = CreateConVar("sm_powerupreverts_dominant", "1", "Enable dominant state in Mannpower", _, true, 0.0, true, 1.0);
	sm_powerupreverts_imbalance_swap = CreateConVar("sm_powerupreverts_imbalance_swap", "0", "Enable imbalance swap in Mannpower", _, true, 0.0, true, 1.0);
	sm_powerupreverts_powerup_glow = CreateConVar("sm_powerupreverts_powerup_glow", "1", "Restore the per-client Mannpower powerup carrier glow", _, true, 0.0, true, 1.0);

	sm_powerupreverts_enable.AddChangeHook(TogglePowerupReverts);
	sm_powerupreverts_dominant.AddChangeHook(ToggleDominant);
	sm_powerupreverts_imbalance_swap.AddChangeHook(ToggleImbalanceSwap);
	sm_powerupreverts_powerup_glow.AddChangeHook(TogglePowerupGlow);

	tf_max_health_boost = FindConVar("tf_max_health_boost");
	tf_powerup_mode = FindConVar("tf_powerup_mode");
	tf_powerup_mode_imbalance_consecutive_min_players = FindConVar("tf_powerup_mode_imbalance_consecutive_min_players");
	tf_powerup_mode_dominant_multiplier = FindConVar("tf_powerup_mode_dominant_multiplier");

	tf_powerup_mode.AddChangeHook(TogglePowerupReverts);

	GameData conf = new GameData("powerupreverts");
	if (conf == null) SetFailState("Failed to load powerupreverts gamedata");

	dhook_CAmmoPack_MyTouch = DynamicHook.FromConf(conf, "CAmmoPack::MyTouch");
	dhook_CCaptureFlag_Think = DynamicHook.FromConf(conf, "CCaptureFlag::Think");
	dhook_CCaptureFlag_PickUp = DynamicHook.FromConf(conf, "CCaptureFlag::PickUp");
	dhook_CCaptureFlag_Drop = DynamicHook.FromConf(conf, "CCaptureFlag::Drop");
	dhook_CTFGameRules_FlPlayerFallDamage = DynamicHook.FromConf(conf, "CTFGameRules::FlPlayerFallDamage");
	dhook_CTFGameRules_SetupOnRoundStart = DynamicHook.FromConf(conf, "CTFGameRules::SetupOnRoundStart");
	dhook_CTFGameRules_SetupOnRoundRunning = DynamicHook.FromConf(conf, "CTFGameRules::SetupOnRoundRunning");
	dhook_CBaseObject_StartBuilding = DynamicHook.FromConf(conf, "CBaseObject::StartBuilding");
	dhook_CBaseObject_CheckUpgradeOnHit = DynamicHook.FromConf(conf, "CBaseObject::CheckUpgradeOnHit");
	dhook_CBaseObject_StartUpgrading = DynamicHook.FromConf(conf, "CBaseObject::StartUpgrading");
	dhook_CTFWeaponBaseMelee_DoMeleeDamage = DynamicHook.FromConf(conf, "CTFWeaponBaseMelee::DoMeleeDamage");
	dhook_CTFSniperRifle_GetProjectileDamage = DynamicHook.FromConf(conf, "CTFSniperRifle::GetProjectileDamage");
	dhook_CTFWeaponBase_PrimaryAttack = DynamicHook.FromConf(conf, "CTFWeaponBase::PrimaryAttack");
	dhook_CWeaponMedigun_GetHealRate = DynamicHook.FromConf(conf, "CWeaponMedigun::GetHealRate");
	dhook_CTFPlayer_EventKilled = DynamicHook.FromConf(conf, "CTFPlayer::Event_Killed");
	dhook_CTFGlow_UpdateTransmitState = DynamicHook.FromConf(conf, "CTFGlow::UpdateTransmitState");

	detour_CTFPlayer_StateEnterACTIVE = DynamicDetour.FromConf(conf, "CTFPlayer::StateEnterACTIVE");
	detour_CCaptureFlag_Capture = DynamicDetour.FromConf(conf, "CCaptureFlag::Capture");
	detour_CWeaponMedigun_GetOverHealBonus = DynamicDetour.FromConf(conf, "CWeaponMedigun::GetOverHealBonus");
	detour_CCaptureZone_Capture = DynamicDetour.FromConf(conf, "CCaptureZone::Capture");
	detour_CTFRadiusDamageInfo_CalculateFalloff = DynamicDetour.FromConf(conf, "CTFRadiusDamageInfo::CalculateFalloff");
	detour_CObjectSapper_SapperThink = DynamicDetour.FromConf(conf, "CObjectSapper::SapperThink");
	detour_CTFPlayerShared_ConditionThink = DynamicDetour.FromConf(conf, "CTFPlayerShared::ConditionThink");
	detour_CWeaponMedigun_FindAndHealTargets = DynamicDetour.FromConf(conf, "CWeaponMedigun::FindAndHealTargets");
	detour_CTFPlayer_TFPlayerThink = DynamicDetour.FromConf(conf, "CTFPlayer::TFPlayerThink");
	detour_CTFAmmoPack_PackTouch = DynamicDetour.FromConf(conf, "CTFAmmoPack::PackTouch");

	patch_HeavyGrappleJumpBoost = MemoryPatch.CreateFromConf(conf, "CTFGameMovement::CheckJumpButton_HeavyGrappleJumpBoost");
	if (patch_HeavyGrappleJumpBoost == null || !patch_HeavyGrappleJumpBoost.Validate()) {
		LogError("Failed to create CTFGameMovement::CheckJumpButton_HeavyGrappleJumpBoost memory patch");
		patch_HeavyGrappleJumpBoost = null;
	}
	delete conf;

	#define VALIDATE_HANDLE(%1) if (%1 == null) SetFailState("Failed to hook " ... #%1)

	VALIDATE_HANDLE(dhook_CAmmoPack_MyTouch);
	VALIDATE_HANDLE(dhook_CCaptureFlag_Think);
	VALIDATE_HANDLE(dhook_CCaptureFlag_PickUp);
	VALIDATE_HANDLE(dhook_CCaptureFlag_Drop);
	VALIDATE_HANDLE(dhook_CTFGameRules_FlPlayerFallDamage);
	VALIDATE_HANDLE(dhook_CTFGameRules_SetupOnRoundStart);
	VALIDATE_HANDLE(dhook_CTFGameRules_SetupOnRoundRunning);
	VALIDATE_HANDLE(dhook_CTFWeaponBase_PrimaryAttack);
	VALIDATE_HANDLE(dhook_CBaseObject_StartBuilding);
	VALIDATE_HANDLE(dhook_CBaseObject_CheckUpgradeOnHit);
	VALIDATE_HANDLE(dhook_CBaseObject_StartUpgrading);
	VALIDATE_HANDLE(dhook_CTFWeaponBaseMelee_DoMeleeDamage);
	VALIDATE_HANDLE(dhook_CTFSniperRifle_GetProjectileDamage);
	VALIDATE_HANDLE(dhook_CWeaponMedigun_GetHealRate);
	VALIDATE_HANDLE(dhook_CTFPlayer_EventKilled);
	VALIDATE_HANDLE(dhook_CTFGlow_UpdateTransmitState);

	VALIDATE_HANDLE(detour_CTFPlayer_StateEnterACTIVE);
	VALIDATE_HANDLE(detour_CCaptureFlag_Capture);
	VALIDATE_HANDLE(detour_CWeaponMedigun_GetOverHealBonus);
	VALIDATE_HANDLE(detour_CCaptureZone_Capture);
	VALIDATE_HANDLE(detour_CTFRadiusDamageInfo_CalculateFalloff);
	VALIDATE_HANDLE(detour_CObjectSapper_SapperThink);
	VALIDATE_HANDLE(detour_CTFPlayerShared_ConditionThink);
	VALIDATE_HANDLE(detour_CWeaponMedigun_FindAndHealTargets);
	VALIDATE_HANDLE(detour_CTFPlayer_TFPlayerThink);
	VALIDATE_HANDLE(detour_CTFAmmoPack_PackTouch);

	g_bDetoursEnabled = false;

	LogMessage(PLUGIN_NAME ... " has loaded.");
}

public void OnPluginEnd() {
	DisablePowerupReverts();
	LogMessage(PLUGIN_NAME ... " has unloaded.");
}

public void OnConfigsExecuted() {
	EnablePowerupReverts();
}

public void TogglePowerupReverts(ConVar convar, const char[] oldValue, const char[] newValue) {
	if (convar.BoolValue) {
		EnablePowerupReverts();
		return;
	}

	DisablePowerupReverts();
}

public void ToggleDominant(ConVar convar, const char[] oldValue, const char[] newValue) {
	if (!IsRevertedPowerupMode())
		return;

	if (convar.BoolValue == false) {
		tf_powerup_mode_dominant_multiplier.IntValue = 999;
	} else {
		tf_powerup_mode_dominant_multiplier.RestoreDefault();
	}
}

public void ToggleImbalanceSwap(ConVar convar, const char[] oldValue, const char[] newValue) {
	if (!IsRevertedPowerupMode())
		return;

	if (convar.BoolValue == false) {
		tf_powerup_mode_imbalance_consecutive_min_players.IntValue = 999;
	} else {
		tf_powerup_mode_imbalance_consecutive_min_players.RestoreDefault();
	}
}

public void TogglePowerupGlow(ConVar convar, const char[] oldValue, const char[] newValue) {
	if (!convar.BoolValue)
		ClearAllPlayerGlows();
}

public void OnMapStart() {
	for (int i = 0; i < MAX_ENTITIES; i++) {
		ResetFlagGlow(i);
		glow_entities[i].target = -1;
		glow_entities[i].route = GLOW_ROUTE_FLAG;
		glow_entities[i].group = GLOW_GROUP_TEAM;
	}

	for (int target = 1; target <= MaxClients; target++) {
		for (GlowGroup group = GLOW_GROUP_TEAM; group < GLOW_GROUP_COUNT; group++) {
			ResetPlayerGlow(target, group);
		}
	}
}

public void OnEntityDestroyed(int entity) {
	if (entity <= MaxClients || entity >= MAX_ENTITIES)
		return;

	// A destroyed glow must not leave stale routing metadata on a reused slot.
	int target = glow_entities[entity].target;
	GlowRoute route = glow_entities[entity].route;
	GlowGroup group = glow_entities[entity].group;
	if (
		route == GLOW_ROUTE_SHARED_PLAYER &&
		target >= 1 && target <= MaxClients &&
		group >= GLOW_GROUP_TEAM && group < GLOW_GROUP_COUNT &&
		player_glows[target][group].glow == entity
	) {
		ResetPlayerGlow(target, group);
	}
	else if (
		route == GLOW_ROUTE_FLAG &&
		target > MaxClients && target < MAX_ENTITIES &&
		flag_glows[target].glow == entity
	) {
		// Otherwise the flag keeps the recycled index and never recreates its glow
		ResetFlagGlow(target);
	}
	glow_entities[entity].target = -1;
	glow_entities[entity].route = GLOW_ROUTE_FLAG;
	glow_entities[entity].group = GLOW_GROUP_TEAM;

	if (flag_glows[entity].glow <= 0)
		return;

	if (IsValidEntity(flag_glows[entity].glow)) {
		RemoveEntity(flag_glows[entity].glow);
	}
	ResetFlagGlow(entity);
}

int frame;
public void OnGameFrame() {
	if (!IsRevertedPowerupMode())
		return;

	frame++;
	int client;

	for (client = 1; client <= MaxClients; client++) {
		UpdateFreeRide(client);
	}

	if (frame % GLOW_REFRESH_INTERVAL == 0) {
		UpdatePowerupGlows();
	}

	if (frame & 6 == 0) {
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

			float time = GetEntPropFloat(flag, Prop_Send, "m_flTimeToSetPoisonous") - GetGameTime();
			if (time > 0.0)
			{
				int second = RoundToCeil(time);
				if (second != players[client].last_displayed_second) {
					players[client].last_displayed_second = second;

					SetHudTextParams(-1.0, 0.925, 1.1, 255, 255, 255, 255, 0, 0.0, 0.0, 0.0);
					ShowSyncHudText(client, hudsync, "Poison in %ds", second);
				}
			}
			else
			{
				players[client].flag = -1;
				players[client].last_displayed_second = -1;
			}
		}
	}
}

public void OnClientPutInServer(int client) {
	if (!IsRevertedPowerupMode())
		return;

	SDKHook(client, SDKHook_OnTakeDamage, SDKHookCB_OnTakeDamage);
	SDKHook(client, SDKHook_OnTakeDamageAlive, SDKHookCB_OnTakeDamageAlive);
	SDKHook(client, SDKHook_OnTakeDamagePost, SDKHookCB_OnTakeDamagePost);
	SDKHook(client, SDKHook_Spawn, SDKHookCB_Spawn);
	SDKHook(client, SDKHook_SpawnPost, SDKHookCB_SpawnPost);
	dhook_CTFPlayer_EventKilled.HookEntity(Hook_Pre, client, DHookCallback_ThisParams_Pre);
	dhook_CTFPlayer_EventKilled.HookEntity(Hook_Post, client, DHookCallback_ThisParams_Post);
}

// Handles rune drop on disconnect
public void OnClientDisconnect(int client) {
	if (!IsRevertedPowerupMode())
		return;

	ResetPowerupModeProp();
	ClearFreeRide(client);
	// Rebuild shared recipient sets after a client slot leaves.
	ClearAllPlayerGlows();

	players[client].flag = -1;
	players[client].last_displayed_second = -1;
}
public void OnClientDisconnect_Post(int client) {
	if (!IsRevertedPowerupMode())
		return;

	ZeroPowerupModeProp();
}

public void OnEntityCreated(int entity, const char[] class) {
	if (!IsRevertedPowerupMode() || entity < 0 || entity >= MAX_ENTITIES)
		return;

	if (IsWeapon(class)) {
		SDKHook(entity, SDKHook_SpawnPost, SDKHookCB_SpawnPostWeapon);
	}

	if (StrStartsWith(class, "obj_")) {
		SDKHook(entity, SDKHook_OnTakeDamage, SDKHookCB_OnTakeDamage_Building);
		SDKHook(entity, SDKHook_OnTakeDamagePost, SDKHookCB_OnTakeDamagePost_Building);
		dhook_CBaseObject_StartBuilding.HookEntity(Hook_Pre, entity, DHookCallback_ThisReturnParams_Pre);
		dhook_CBaseObject_StartBuilding.HookEntity(Hook_Post, entity, DHookCallback_ThisReturnParams_Post);
		dhook_CBaseObject_CheckUpgradeOnHit.HookEntity(Hook_Pre, entity, DHookCallback_ThisReturnParams_Pre);
		dhook_CBaseObject_CheckUpgradeOnHit.HookEntity(Hook_Post, entity, DHookCallback_ThisReturnParams_Post);
		dhook_CBaseObject_StartUpgrading.HookEntity(Hook_Pre, entity, DHookCallback_This_Pre);
		dhook_CBaseObject_StartUpgrading.HookEntity(Hook_Post, entity, DHookCallback_This_Post);
	}
	else if (StrEqual(class, "tf_weapon_medigun")) {
		dhook_CWeaponMedigun_GetHealRate.HookEntity(Hook_Pre, entity, DHookCallback_CWeaponMedigun_Pre);
		dhook_CWeaponMedigun_GetHealRate.HookEntity(Hook_Post, entity, DHookCallback_ThisReturn_Post);
	}
	else if (StrStartsWith(class, "tf_weapon_sniperrifle")) {
		dhook_CTFSniperRifle_GetProjectileDamage.HookEntity(Hook_Pre, entity, DHookCallback_ThisReturn_Pre);
		dhook_CTFSniperRifle_GetProjectileDamage.HookEntity(Hook_Post, entity, DHookCallback_ThisReturn_Post);
	}
	else if (StrEqual(class, "tf_weapon_knife")) {
		dhook_CTFWeaponBase_PrimaryAttack.HookEntity(Hook_Pre, entity, DHookCallback_CTFKnife_PrimaryAttack_Pre);
		dhook_CTFWeaponBase_PrimaryAttack.HookEntity(Hook_Post, entity, DHookCallback_This_Post);
	}
	else if (StrStartsWith(class, "item_ammopack")) {
		dhook_CAmmoPack_MyTouch.HookEntity(Hook_Pre, entity, DHookCallback_CAmmoPack_MyTouch_Pre);
		dhook_CAmmoPack_MyTouch.HookEntity(Hook_Post, entity, DHookCallback_ThisReturnParams_Post);
	}
	else if (StrEqual(class, "item_powerup_rune_temp")) {
		SDKHook(entity, SDKHook_Spawn, SDKHookCB_Spawn);
		SDKHook(entity, SDKHook_SpawnPost, SDKHookCB_SpawnPost);
	}
	else if (StrEqual(class, "item_teamflag")) {
		dhook_CCaptureFlag_Think.HookEntity(Hook_Pre, entity, DHookCallback_This_Pre);
		dhook_CCaptureFlag_Think.HookEntity(Hook_Post, entity, DHookCallback_CCaptureFlag_Think_Post);
		dhook_CCaptureFlag_PickUp.HookEntity(Hook_Pre, entity, DHookCallback_CCaptureFlag_PickUp_Pre);
		dhook_CCaptureFlag_PickUp.HookEntity(Hook_Post, entity, DHookCallback_ThisParams_Post);
		dhook_CCaptureFlag_Drop.HookEntity(Hook_Pre, entity, DHookCallback_ThisParams_Pre);
		dhook_CCaptureFlag_Drop.HookEntity(Hook_Post, entity, DHookCallback_CCaptureFlag_Drop_Post);
	}
}

void SDKHookCB_SpawnPostWeapon(int entity) {
	if (!IsRevertedPowerupMode() || sm_powerupreverts_crits.BoolValue == true)
		return;

	// disable crits
	TF2Attrib_SetByName(entity, "crit mod disabled hidden", 0.0);
}

Action SDKHookCB_OnTakeDamage(
	int victim, int& attacker, int& inflictor, float& damage, int& damage_type,
	int& weapon, float damage_force[3], float damage_position[3], int damage_custom
) {
	if (IsRevertedPowerupMode()) {
		// Prevent powerupmode modifiers for damage...
		ZeroPowerupModeProp();

		if (
			PowerupCarrierPenalties() &&
			attacker >= 1 && attacker <= MaxClients &&
			IsCarryingRune(attacker)
		) {
			// ...unless the attacker is carrying a rune
			ResetPowerupModeProp();
		}

		// Strength increases crit damage
		if (
			damage_type & DMG_CRIT &&
			!PowerupCarrierPenalties() &&
			attacker >= 1 && attacker <= MaxClients &&
			GetCarryingRuneType(attacker) == RUNE_STRENGTH
		) {
			damage *= TF2_IsPlayerInCondition(attacker, TFCond_PowerupModeDominant) ? 1.4 : 2.0;
			return Plugin_Changed;
		}
	}

	return Plugin_Continue;
}
Action SDKHookCB_OnTakeDamageAlive(
	int victim, int& attacker, int& inflictor, float& damage, int& damage_type,
	int& weapon, float damage_force[3], float damage_position[3], int damage_custom
) {
	if (IsRevertedPowerupMode()) {
		// Vampire heal on burn damage
		if (
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
	}
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
			dhook_CTFWeaponBaseMelee_DoMeleeDamage.HookEntity(Hook_Pre, weapon, DHookCallback_ThisParams_Pre);
			dhook_CTFWeaponBaseMelee_DoMeleeDamage.HookEntity(Hook_Post, weapon, DHookCallback_ThisParams_Post);
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

MRESReturn DHookCallback_CCaptureFlag_Think_Post(int entity) {
	ZeroPowerupModeProp();
	SyncFlagGlow(entity);
	return MRES_Ignored;
}

MRESReturn DetourCallback_CWeaponMedigun_GetOverHealBonus_Pre(int entity, DHookReturn returnValue, DHookParam parameters) {
	if (
		IsRevertedPowerupMode() &&
		!PowerupCarrierPenalties()
	) {
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

MRESReturn DHookCallback_CTFPlayerShared_ConditionThink_Pre(Address _this) {
	int client = TF2Util_GetPlayerFromSharedAddress(_this);
	if (
		IsRevertedPowerupMode() &&
		PowerupCarrierPenalties() &&
		client >= 1 && client <= MaxClients &&
		IsCarryingRune(client)
	) {
		ResetPowerupModeProp();
	}
	return MRES_Ignored;
}

MRESReturn DHookCallback_CTFKnife_PrimaryAttack_Pre(int entity) {
	int client = GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity");
	if (
		IsRevertedPowerupMode() &&
		PowerupCarrierPenalties() &&
		client >= 1 && client <= MaxClients &&
		IsCarryingRune(client)
	) {
		ResetPowerupModeProp();
	}
	return MRES_Ignored;
}

MRESReturn DHookCallback_CWeaponMedigun_Pre(int entity, DHookReturn returnValue) {
	if (
		IsRevertedPowerupMode() &&
		PowerupCarrierPenalties()
	) {
		ResetPowerupModeProp();
	}
	return MRES_Ignored;
}

MRESReturn DHookCallback_CAmmoPack_MyTouch_Pre(int entity, DHookReturn returnValue, DHookParam parameters) {
	int client = parameters.Get(1);
	if (
		IsRevertedPowerupMode() &&
		PowerupCarrierPenalties() &&
		client >= 1 && client <= MaxClients &&
		IsCarryingRune(client)
	) {
		ResetPowerupModeProp();
	}
	return MRES_Ignored;
}

MRESReturn DHookCallback_CTFAmmoPack_PackTouch_Pre(int entity, DHookParam parameters) {
	int client = parameters.Get(1);
	if (
		IsRevertedPowerupMode() &&
		PowerupCarrierPenalties() &&
		client >= 1 && client <= MaxClients &&
		IsCarryingRune(client)
	) {
		ResetPowerupModeProp();
	}
	return MRES_Ignored;
}

// Generic callbacks so the plugin doesn't get bloated with a bajillion functions that do the same thing
MRESReturn DHookCallback_This_Pre(int _this) {
	ResetPowerupModeProp();
	return MRES_Ignored;
}
MRESReturn DHookCallback_This_Post(int _this) {
	ZeroPowerupModeProp();
	return MRES_Ignored;
}
MRESReturn DHookCallback_ThisReturn_Pre(int _this, DHookReturn returnValue) {
	ResetPowerupModeProp();
	return MRES_Ignored;
}
MRESReturn DHookCallback_ThisReturn_Post(int _this, DHookReturn returnValue) {
	ZeroPowerupModeProp();
	return MRES_Ignored;
}
MRESReturn DHookCallback_ThisParams_Pre(int _this, DHookParam parameters) {
	ResetPowerupModeProp();
	return MRES_Ignored;
}
MRESReturn DHookCallback_ThisParams_Post(int _this, DHookParam parameters) {
	ZeroPowerupModeProp();
	return MRES_Ignored;
}
MRESReturn DHookCallback_ThisReturnParams_Pre(int _this, DHookReturn returnValue, DHookParam parameters) {
	ResetPowerupModeProp();
	return MRES_Ignored;
}
MRESReturn DHookCallback_ThisReturnParams_Post(int _this, DHookReturn returnValue, DHookParam parameters) {
	ZeroPowerupModeProp();
	return MRES_Ignored;
}

void ResetPowerupModeProp(bool bypass = false) {
	if (!bypass && g_bPowerupRevertsEnabled == false)
		return;

	GameRules_SetProp("m_bPowerupMode", tf_powerup_mode.IntValue);
}

void ZeroPowerupModeProp(bool bypass = false) {
	if (!bypass && g_bPowerupRevertsEnabled == false)
		return;

	GameRules_SetProp("m_bPowerupMode", 0);
}

bool IsRevertedPowerupMode() {
	return tf_powerup_mode.BoolValue && g_bPowerupRevertsEnabled;
}

bool PowerupCarrierPenalties() {
	return sm_powerupreverts_enable.IntValue == 1;
}

void EnablePowerupReverts() {
	if (GameRules_GetProp("m_bPlayingMannVsMachine")) {
		LogMessage("Powerup mode is incompatible with MvM");
		DisablePowerupReverts();
		return;
	}

	g_bPowerupRevertsEnabled = sm_powerupreverts_enable.BoolValue;
	if (IsRevertedPowerupMode()) {
		ZeroPowerupModeProp(true);
		ApplyHeavyGrappleJumpBoost(true);

		ToggleDominant(sm_powerupreverts_dominant, "", "");
		ToggleImbalanceSwap(sm_powerupreverts_imbalance_swap, "", "");

		dhook_CTFGameRules_FlPlayerFallDamage.HookGamerules(Hook_Pre, DHookCallback_ThisReturnParams_Pre);
		dhook_CTFGameRules_FlPlayerFallDamage.HookGamerules(Hook_Post, DHookCallback_ThisReturnParams_Post);
		dhook_CTFGameRules_SetupOnRoundStart.HookGamerules(Hook_Pre, DHookCallback_This_Pre);
		dhook_CTFGameRules_SetupOnRoundStart.HookGamerules(Hook_Post, DHookCallback_This_Post);
		dhook_CTFGameRules_SetupOnRoundRunning.HookGamerules(Hook_Pre, DHookCallback_This_Pre);
		dhook_CTFGameRules_SetupOnRoundRunning.HookGamerules(Hook_Post, DHookCallback_This_Post);

		detour_CTFPlayer_StateEnterACTIVE.Enable(Hook_Pre, DHookCallback_This_Pre);
		detour_CTFPlayer_StateEnterACTIVE.Enable(Hook_Post, DHookCallback_This_Post);
		detour_CCaptureFlag_Capture.Enable(Hook_Pre, DHookCallback_ThisParams_Pre);
		detour_CCaptureFlag_Capture.Enable(Hook_Post, DHookCallback_ThisParams_Post);
		detour_CWeaponMedigun_GetOverHealBonus.Enable(Hook_Pre, DetourCallback_CWeaponMedigun_GetOverHealBonus_Pre);
		detour_CCaptureZone_Capture.Enable(Hook_Pre, DHookCallback_ThisParams_Pre);
		detour_CCaptureZone_Capture.Enable(Hook_Post, DHookCallback_ThisParams_Post);
		detour_CTFRadiusDamageInfo_CalculateFalloff.Enable(Hook_Pre, DHookCallback_This_Pre);
		detour_CTFRadiusDamageInfo_CalculateFalloff.Enable(Hook_Post, DHookCallback_This_Post);
		detour_CObjectSapper_SapperThink.Enable(Hook_Pre, DHookCallback_This_Pre);
		detour_CObjectSapper_SapperThink.Enable(Hook_Post, DHookCallback_This_Post);
		detour_CTFPlayerShared_ConditionThink.Enable(Hook_Pre, DHookCallback_CTFPlayerShared_ConditionThink_Pre);
		detour_CTFPlayerShared_ConditionThink.Enable(Hook_Post, DHookCallback_This_Post);
		detour_CWeaponMedigun_FindAndHealTargets.Enable(Hook_Pre, DHookCallback_CWeaponMedigun_Pre);
		detour_CWeaponMedigun_FindAndHealTargets.Enable(Hook_Post, DHookCallback_ThisReturn_Post);
		detour_CTFPlayer_TFPlayerThink.Enable(Hook_Pre, DHookCallback_This_Pre);
		detour_CTFPlayer_TFPlayerThink.Enable(Hook_Post, DHookCallback_This_Post);
		detour_CTFAmmoPack_PackTouch.Enable(Hook_Pre, DHookCallback_CTFAmmoPack_PackTouch_Pre);
		detour_CTFAmmoPack_PackTouch.Enable(Hook_Post, DHookCallback_ThisParams_Post);

		g_bDetoursEnabled = true;

		for (int i = 1; i <= MaxClients; i++) {
			//if (IsClientConnected(i)) OnClientConnected(i);
			if (IsClientInGame(i)) OnClientPutInServer(i);
		}

		for (int i = MaxClients + 1; i < MAX_ENTITIES; i++) {
			char class[64];
			if (IsValidEntity(i)) {
				GetEntityClassname(i, class, sizeof(class));
				OnEntityCreated(i, class);

				// Flags are already spawned at this point, so the glow can be set up right away
				if (StrEqual(class, "item_teamflag")) {
					SyncFlagGlow(i);
				}
			}
		}

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
	ClearAllGlows();

	tf_powerup_mode_dominant_multiplier.RestoreDefault();
	tf_powerup_mode_imbalance_consecutive_min_players.RestoreDefault();

	if (g_bDetoursEnabled) {
		detour_CTFPlayer_StateEnterACTIVE.Disable(Hook_Pre, DHookCallback_This_Pre);
		detour_CTFPlayer_StateEnterACTIVE.Disable(Hook_Post, DHookCallback_This_Post);
		detour_CCaptureFlag_Capture.Disable(Hook_Pre, DHookCallback_ThisParams_Pre);
		detour_CCaptureFlag_Capture.Disable(Hook_Post, DHookCallback_ThisParams_Post);
		detour_CWeaponMedigun_GetOverHealBonus.Disable(Hook_Pre, DetourCallback_CWeaponMedigun_GetOverHealBonus_Pre);
		detour_CCaptureZone_Capture.Disable(Hook_Pre, DHookCallback_ThisParams_Pre);
		detour_CCaptureZone_Capture.Disable(Hook_Post, DHookCallback_ThisParams_Post);
		detour_CTFRadiusDamageInfo_CalculateFalloff.Disable(Hook_Pre, DHookCallback_This_Pre);
		detour_CTFRadiusDamageInfo_CalculateFalloff.Disable(Hook_Post, DHookCallback_This_Post);
		detour_CObjectSapper_SapperThink.Disable(Hook_Pre, DHookCallback_This_Pre);
		detour_CObjectSapper_SapperThink.Disable(Hook_Post, DHookCallback_This_Post);
		detour_CTFPlayerShared_ConditionThink.Disable(Hook_Pre, DHookCallback_CTFPlayerShared_ConditionThink_Pre);
		detour_CTFPlayerShared_ConditionThink.Disable(Hook_Post, DHookCallback_This_Post);
		detour_CWeaponMedigun_FindAndHealTargets.Disable(Hook_Pre, DHookCallback_CWeaponMedigun_Pre);
		detour_CWeaponMedigun_FindAndHealTargets.Disable(Hook_Post, DHookCallback_ThisReturn_Post);
		detour_CTFPlayer_TFPlayerThink.Disable(Hook_Pre, DHookCallback_This_Pre);
		detour_CTFPlayer_TFPlayerThink.Disable(Hook_Post, DHookCallback_This_Post);
		detour_CTFAmmoPack_PackTouch.Disable(Hook_Pre, DHookCallback_CTFAmmoPack_PackTouch_Pre);
		detour_CTFAmmoPack_PackTouch.Disable(Hook_Post, DHookCallback_ThisParams_Post);

		g_bDetoursEnabled = false;
	}

	LogMessage("Mannpower Reverts disabled");
}

void ApplyHeavyGrappleJumpBoost(bool enable) {
	if (patch_HeavyGrappleJumpBoost == null)
		return;

	if (enable) {
		if (patch_HeavyGrappleJumpBoost.Enable()) {
			LogMessage("Heavy grapple jump boost revert enabled");
		}
	} else {
		patch_HeavyGrappleJumpBoost.Disable();
		LogMessage("Heavy grapple jump boost revert disabled");
	}
}

void ClearFreeRide(int client) {
	if (players[client].free_ride_patient == 0)
		return;

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

TFCond GetConditionFromRuneType(RuneTypes_t rune) {
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

static RuneTypes_t GetCarryingRuneType(int client) {
    RuneTypes_t rune = RUNE_NONE;
    for (RuneTypes_t i = view_as<RuneTypes_t>(0); i < RUNE_TYPES_MAX; ++i) {
        if (TF2_IsPlayerInCondition(client, GetConditionFromRuneType(i))) {
            rune = i;
            break;
        }
    }
    return rune;
}

bool IsCarryingRune(int client) {
	return GetCarryingRuneType(client) != RUNE_NONE;
}

bool IsGlowLineOfSightClear(int viewer, int target) {
	float start[3], end[3];
	GetClientEyePosition(viewer, start);
	GetClientEyePosition(target, end);

	Handle trace = TR_TraceRayFilterEx(
		start, end, MASK_VISIBLE_AND_NPCS, RayType_EndPoint, TraceFilter_GlowLineOfSight
	);
	bool clear = !TR_DidHit(trace);
	delete trace;
	return clear;
}

public bool TraceFilter_GlowLineOfSight(int entity, int contentsMask, any data) {
	if (entity == 0)
		return true;

	if (entity <= MaxClients)
		return false;

	char classname[64];
	return !GetEntityClassname(entity, classname, sizeof(classname)) || !IsWeapon(classname);
}

// man the following bullshit wouldn't even be necessary if team switching was allowed in mannpower

// ----------------------------------------------------------------------------
// Glow support
//
// tf_glow state is global, so player glows are shared only when color and the
// eligible observer set match. A set change recreates the entity to clear old
// client-side glow objects for observers that are no longer eligible.
// ----------------------------------------------------------------------------

void ResetFlagGlow(int flag) {
	flag_glows[flag].glow = 0;
	flag_glows[flag].enabled = false;
}

void ResetPlayerGlow(int target, GlowGroup group) {
	player_glows[target][group].glow = 0;
	player_glows[target][group].color = 0;
	for (int observer = 0; observer <= MaxClients; observer++) {
		player_glows[target][group].observers[observer] = false;
		player_glows[target][group].desired_observers[observer] = false;
	}
	player_glows[target][group].idle = 0;
}

void DestroyPlayerGlow(int target, GlowGroup group) {
	int glow = player_glows[target][group].glow;
	if (glow > 0 && IsValidEntity(glow)) {
		glow_entities[glow].route = GLOW_ROUTE_DESTROYING;
		RemoveEntity(glow);
	}
	ResetPlayerGlow(target, group);
}

void ClearAllPlayerGlows() {
	for (int target = 1; target <= MaxClients; target++) {
		for (GlowGroup group = GLOW_GROUP_TEAM; group < GLOW_GROUP_COUNT; group++) {
			DestroyPlayerGlow(target, group);
		}
	}
}

int PackColor(const int color[4]) {
	return color[0] | (color[1] << 8) | (color[2] << 16) | (color[3] << 24);
}

void GetTeamGlowColor(int team, int color[4]) {
	switch (view_as<TFTeam>(team)) {
		case TFTeam_Red: {
			color[0] = 189; color[1] = 59; color[2] = 59;		// 0.74, 0.23, 0.23
		}
		case TFTeam_Blue: {
			color[0] = 125; color[1] = 168; color[2] = 196;		// 0.49, 0.66, 0.77
		}
		default: {
			color[0] = 194; color[1] = 194; color[2] = 194;		// 0.76, 0.76, 0.76
		}
	}
	color[3] = 255;
}

int SpawnGlowEntity(int target, const int color[4], GlowRoute route, GlowGroup group = GLOW_GROUP_TEAM) {
	if (target <= 0 || target >= MAX_ENTITIES)
		return -1;

	// CTFGlow::Spawn resolves its target by name, so the target is given a name if
	// it does not have one. The name is left in place to avoid churning the engine
	// string pool on every glow creation.
	char target_name[128];
	GetEntPropString(target, Prop_Data, "m_iName", target_name, sizeof(target_name));
	if (target_name[0] == '\0') {
		FormatEx(target_name, sizeof(target_name), "pwrup_glow_%d", target);
		SetEntPropString(target, Prop_Data, "m_iName", target_name);
	}

	int glow = CreateEntityByName("tf_glow");
	if (glow <= 0) {
		LogError("Failed to create tf_glow for entity %d", target);
		return -1;
	}

	char buffer[32];
	FormatEx(buffer, sizeof(buffer), "%d %d %d %d", color[0], color[1], color[2], color[3]);

	// Mode 0 draws both occluded and visible. Mode 2 (visible only) was seen to keep
	// drawing through walls, so occlusion is handled by the server line of sight
	// check instead of by the glow mode.
	DispatchKeyValue(glow, "target", target_name);
	DispatchKeyValue(glow, "Mode", "0");
	DispatchKeyValue(glow, "StartDisabled", "1");
	DispatchKeyValue(glow, "GlowColor", buffer);
	DispatchSpawn(glow);

	// CTFGlow removes itself when its target cannot be found
	if (!IsValidEntity(glow) || GetEntPropEnt(glow, Prop_Send, "m_hTarget") != target) {
		LogError("tf_glow failed to target entity %d", target);
		if (IsValidEntity(glow))
			RemoveEntity(glow);
		return -1;
	}

	// Entity slots are reused, so routing metadata is rewritten on every creation.
	glow_entities[glow].route = route;
	glow_entities[glow].target = target;
	glow_entities[glow].group = group;

	if (
		dhook_CTFGlow_UpdateTransmitState.HookEntity(Hook_Pre, glow, DHookCallback_GlowUpdateTransmitState) == INVALID_HOOK_ID ||
		!SDKHookEx(glow, SDKHook_SetTransmit, SDKHookCB_GlowTransmit)
	) {
		LogError("Failed to hook transmission for tf_glow %d", glow);
		RemoveEntity(glow);
		return -1;
	}
	// Start in full-check mode; FL_EDICT_ALWAYS would bypass SDKHook_SetTransmit.
	SetEdictFlags(glow, GetEdictFlags(glow) & ~(FL_EDICT_ALWAYS | FL_EDICT_DONTSEND | FL_EDICT_PVSCHECK));
	return glow;
}

MRESReturn DHookCallback_GlowUpdateTransmitState(int entity, DHookReturn returnValue) {
	// Avoid PVS culling, but skip the original's SetTransmitState side effect,
	// which would persist FL_EDICT_ALWAYS and bypass the per-client transmit hook.
	returnValue.Value = FL_EDICT_ALWAYS;
	return MRES_Supercede;
}

public Action SDKHookCB_GlowTransmit(int entity, int observer) {
	GlowRoute route = glow_entities[entity].route;
	if (route == GLOW_ROUTE_SHARED_PLAYER) {
		int target = glow_entities[entity].target;
		GlowGroup group = glow_entities[entity].group;
		if (
			observer < 1 || observer > MaxClients ||
			target < 1 || target > MaxClients ||
			group < GLOW_GROUP_TEAM || group >= GLOW_GROUP_COUNT
		) {
			return Plugin_Handled;
		}
		return player_glows[target][group].observers[observer] ? Plugin_Continue : Plugin_Handled;
	}
	else if (
		route == GLOW_ROUTE_DESTROYING ||
		route != GLOW_ROUTE_FLAG
	)
		return Plugin_Handled;

	// A flag glow stands in for the engine outline, which is hidden only from the
	// team the flag belongs to (CCaptureFlag::ShouldHideGlowEffect)
	int flag = GetEntPropEnt(entity, Prop_Send, "m_hTarget");
	if (flag <= 0)
		return Plugin_Handled;

	return (GetClientTeam(observer) == GetEntProp(flag, Prop_Send, "m_iTeamNum")) ? Plugin_Continue : Plugin_Handled;
}

// ----------------------------------------------------------------------------
// Flag glow
//
// In powerup mode CCaptureFlag::ShouldHideGlowEffect never hides the outline,
// so a stolen intelligence keeps glowing for the team that owns it. Reverting
// powerup mode removes that behaviour, so it is restored here with a tf_glow
// that is enabled while the flag is stolen. The engine outline is hidden from
// the owning team only while the flag is stolen, so this glow is transmitted to
// that team alone and never doubles up the engine's own outline.
//
// The carrier's own outline is left entirely to the engine: ItemPostFrame feeds
// ShouldHideGlowEffect to the player glow object, so an enemy carrying your intel
// has no outline for you (stock CTF) while their own team sees it health coloured.
// Powerup mode shows it to everyone, but that is deliberately not restored.
// ----------------------------------------------------------------------------

void SetFlagGlowEnabled(int flag, bool enable) {
	int glow = flag_glows[flag].glow;
	if (glow <= 0 || flag_glows[flag].enabled == enable)
		return;

	if (!IsValidEntity(glow)) {
		ResetFlagGlow(flag);
		return;
	}

	AcceptEntityInput(glow, enable ? "Enable" : "Disable");
	flag_glows[flag].enabled = enable;
}

void SyncFlagGlow(int flag) {
	if (!IsRevertedPowerupMode() || flag <= 0 || flag >= MAX_ENTITIES || !IsValidEntity(flag))
		return;

	// TF_FLAGINFO_STOLEN, and honour maps and plugins that disabled the glow
	// entirely (ForceGlowDisabled zeroes m_bGlowEnabled)
	if (
		(GetEntProp(flag, Prop_Send, "m_nFlagStatus") & 1) == 0 ||
		GetEntProp(flag, Prop_Send, "m_bGlowEnabled") == 0
	) {
		SetFlagGlowEnabled(flag, false);

		// A failed creation is retried the next time the flag is stolen instead of
		// every refresh, which would flood the log
		if (flag_glows[flag].glow < 0)
			ResetFlagGlow(flag);
		return;
	}

	// m_bGlowEnabled is deliberately left alone: it also decides whether the flag
	// carrier's own outline is drawn (CCaptureFlag::ShouldHideGlowEffect is used
	// for both, so zeroing it kills the carrier glow)
	if (flag_glows[flag].glow == 0) {
		int color[4];
		GetTeamGlowColor(GetEntProp(flag, Prop_Send, "m_iTeamNum"), color);
		flag_glows[flag].glow = SpawnGlowEntity(flag, color, GLOW_ROUTE_FLAG);
	}

	if (flag_glows[flag].glow > 0)
		SetFlagGlowEnabled(flag, true);
}

// ----------------------------------------------------------------------------
// Powerup carrier glow eligibility
//
// Mirrors C_TFPlayer::ShouldShowPowerupGlowEffect: enemies carrying a rune glow
// for observers without a rune when below 30% health, and a charged Supernova
// reveals nearby enemies within 1500 units. Mode 2 handles wall occlusion on
// the client. Dead players and spectators use their spectator target's position.
// ----------------------------------------------------------------------------

void GetPowerupGlowColor(RuneTypes_t observer_rune, int target, int color[4]) {
	// C_TFPlayer::GetPowerupGlowEffectColor
	if (observer_rune == RUNE_SUPERNOVA) {
		color[0] = 255; color[1] = 255; color[2] = 0; color[3] = 255;
		return;
	}

	// C_TFPlayer::GetGlowEffectColor: CTFPlayer::HasTheFlag makes intel carriers use a health colour
	int item = GetEntPropEnt(target, Prop_Send, "m_hItem");
	char item_class[32];
	if (
		item > 0 && item < MAX_ENTITIES &&
		GetEntityClassname(item, item_class, sizeof(item_class)) &&
		StrEqual(item_class, "item_teamflag")
	) {
		int max_health = TF2Util_GetEntityMaxHealth(target);
		float health = (max_health > 0) ? (float(GetClientHealth(target)) / float(max_health)) : 1.0;

		if (health > 0.6) {
			color[0] = 84; color[1] = 191; color[2] = 59;
		}
		else if (health > 0.3) {
			color[0] = 191; color[1] = 184; color[2] = 59;
		}
		else {
			color[0] = 191; color[1] = 59; color[2] = 59;
		}
		color[3] = 255;
		return;
	}

	int team = GetClientTeam(target);

	// Disguised spies glow with their disguise colour, like on the client
	if (
		TF2_GetPlayerClass(target) == TFClass_Spy &&
		TF2_IsPlayerInCondition(target, TFCond_Disguised)
	) {
		TFTeam disguise_team = view_as<TFTeam>(GetEntProp(target, Prop_Send, "m_nDisguiseTeam"));
		if (disguise_team >= TFTeam_Red && disguise_team <= TFTeam_Blue)
		{
			team = view_as<int>(disguise_team);
		}
	}

	GetTeamGlowColor(team, color);
}

void ClearAllGlows() {
	for (int i = 1; i < MAX_ENTITIES; i++) {
		int glow = flag_glows[i].glow;
		if (glow > 0 && IsValidEntity(glow))
			RemoveEntity(glow);

		ResetFlagGlow(i);
	}

	ClearAllPlayerGlows();
}

void SyncPlayerGlowGroup(int target, GlowGroup group) {
	bool has_recipients = false;
	bool recipients_changed = false;
	for (int observer = 1; observer <= MaxClients; observer++) {
		bool desired = player_glows[target][group].desired_observers[observer];
		has_recipients = has_recipients || desired;
		if (player_glows[target][group].observers[observer] != desired)
			recipients_changed = true;
	}

	int glow = player_glows[target][group].glow;
	if (!has_recipients) {
		// Hide the glow as soon as the last recipient loses line of sight, but keep
		// the entity for a few refreshes: the old recipients keep receiving it,
		// which is what makes the disable reach their client, and enabling it again
		// is cheaper than a new creation
		if (glow > 0 && IsValidEntity(glow)) {
			if (player_glows[target][group].idle == 0)
				AcceptEntityInput(glow, "Disable");

			if (++player_glows[target][group].idle < GLOW_CULL_GRACE_REFRESHES)
				return;
		}

		if (glow != 0)
			DestroyPlayerGlow(target, group);
		return;
	}

	player_glows[target][group].idle = 0;

	// A failed creation must not be retried every refresh, or it floods the log
	if (glow < 0)
		return;

	if (
		glow > 0 &&
		(!IsValidEntity(glow) || GetEntPropEnt(glow, Prop_Send, "m_hTarget") != target)
	) {
		DestroyPlayerGlow(target, group);
		glow = 0;
		recipients_changed = true;
	}

	int color[4];
	GetPowerupGlowColor(group == GLOW_GROUP_SUPERNOVA ? RUNE_SUPERNOVA : RUNE_NONE, target, color);
	int packed_color = PackColor(color);
	if (glow == 0 || recipients_changed) {
		if (glow > 0)
			DestroyPlayerGlow(target, group);

		glow = SpawnGlowEntity(target, color, GLOW_ROUTE_SHARED_PLAYER, group);
		if (glow <= 0) {
			player_glows[target][group].glow = -1;
			return;
		}

		player_glows[target][group].glow = glow;
		player_glows[target][group].color = packed_color;
		for (int observer = 1; observer <= MaxClients; observer++) {
			player_glows[target][group].observers[observer] = player_glows[target][group].desired_observers[observer];
		}
		AcceptEntityInput(glow, "Enable");
		return;
	}

	if (packed_color != player_glows[target][group].color) {
		player_glows[target][group].color = packed_color;
		SetVariantColor(color);
		AcceptEntityInput(glow, "SetGlowColor");
	}

	// No-op unless the glow was disabled while culled
	AcceptEntityInput(glow, "Enable");
}

enum struct client_condition {
	bool alive;
	bool low_health_rune_carrier;
	bool stealthed;
	bool stealth_checked;
	bool charged_supernova;
	RuneTypes_t rune;
	int team;
	float center[3];
}
client_condition conditions[MAXPLAYERS + 1];

void UpdatePowerupGlows() {
	if (!sm_powerupreverts_powerup_glow.BoolValue)
		return;

	// Build each carrier/color recipient set, then allocate at most one glow for it.
	for (int client = 1; client <= MaxClients; client++) {
		conditions[client].alive = IsClientInGame(client) && IsPlayerAlive(client);

		// Dead players keep their team, so a spectator still filters by it
		conditions[client].team = IsClientInGame(client) ? GetClientTeam(client) : 0;
		conditions[client].rune = RUNE_NONE;
		conditions[client].low_health_rune_carrier = false;
		conditions[client].stealthed = false;
		conditions[client].charged_supernova = false;
		conditions[client].stealth_checked = false;

		if (!conditions[client].alive)
			continue;

		conditions[client].rune = GetCarryingRuneType(client);
		if (conditions[client].rune != RUNE_NONE) {
			int max_health = TF2Util_GetEntityMaxHealth(client);
			conditions[client].low_health_rune_carrier = max_health > 0 &&
				(float(GetClientHealth(client)) / float(max_health)) <= GLOW_LOW_HEALTH_RATIO;
		}
		conditions[client].charged_supernova = conditions[client].rune == RUNE_SUPERNOVA &&
			GetEntPropFloat(client, Prop_Send, "m_flRuneCharge") >= 100.0;

		// CBaseEntity::WorldSpaceCenter, used by the client for the distance check
		float mins[3], maxs[3];
		GetClientAbsOrigin(client, conditions[client].center);
		GetClientMins(client, mins);
		GetClientMaxs(client, maxs);

		for (int axis = 0; axis < 3; axis++) {
			conditions[client].center[axis] += (mins[axis] + maxs[axis]) * 0.5;
		}
	}

	for (int target = 1; target <= MaxClients; target++) {
		for (GlowGroup group = GLOW_GROUP_TEAM; group < GLOW_GROUP_COUNT; group++) {
			for (int observer = 1; observer <= MaxClients; observer++) {
				player_glows[target][group].desired_observers[observer] = false;
			}
		}
	}

	for (int observer = 1; observer <= MaxClients; observer++) {
		if (
			!IsClientInGame(observer) ||
			IsFakeClient(observer) ||
			IsClientReplay(observer) ||
			IsClientSourceTV(observer)
		) {
			continue;
		}

		// Dead players and spectators use their spectated player's position.
		int viewer = observer;
		if (!conditions[observer].alive) {
			viewer = GetEntPropEnt(observer, Prop_Send, "m_hObserverTarget");
			if (viewer < 1 || viewer > MaxClients || viewer == observer || !conditions[viewer].alive)
				continue;
		}

		// A plain spectator has no game team, so it filters by the spectated
		// player's team instead of seeing both teams' carriers. Dead players keep
		// their own team.
		int observer_team = conditions[observer].team;
		if (observer_team < view_as<int>(TFTeam_Red) || observer_team > view_as<int>(TFTeam_Blue))
			observer_team = conditions[viewer].team;

		RuneTypes_t rune = conditions[observer].rune;

		for (int target = 1; target <= MaxClients; target++) {
			if (!conditions[target].alive || target == observer || conditions[target].team == observer_team)
				continue;

			bool team_glow = rune == RUNE_NONE && conditions[target].low_health_rune_carrier;
			bool supernova_glow = false;

			// A charged Supernova reveals every nearby enemy that is not stealthed
			// (TF_COND_STEALTHED, TF_COND_STEALTHED_USER_BUFF, TF_COND_STEALTHED_USER_BUFF_FADING)
			if (
				conditions[observer].charged_supernova &&
				GetVectorDistance(conditions[viewer].center, conditions[target].center, true) <= GLOW_SUPERNOVA_RADIUS_SQR
			) {
				if (!conditions[target].stealth_checked) {
					conditions[target].stealthed =
						TF2_IsPlayerInCondition(target, TFCond_Cloaked) ||
						TF2_IsPlayerInCondition(target, TFCond_Stealthed) ||
						TF2_IsPlayerInCondition(target, TFCond_StealthedUserBuffFade);
					conditions[target].stealth_checked = true;
				}
				supernova_glow = !conditions[target].stealthed;
			}

			if ((team_glow || supernova_glow) && IsGlowLineOfSightClear(viewer, target)) {
				if (team_glow)
					player_glows[target][GLOW_GROUP_TEAM].desired_observers[observer] = true;
				if (supernova_glow)
					player_glows[target][GLOW_GROUP_SUPERNOVA].desired_observers[observer] = true;
			}
		}
	}

	for (int target = 1; target <= MaxClients; target++) {
		for (GlowGroup group = GLOW_GROUP_TEAM; group < GLOW_GROUP_COUNT; group++)
			SyncPlayerGlowGroup(target, group);
	}
}

stock bool StrStartsWith(const char[] str, const char[] prefix) {
	return strncmp(str, prefix, strlen(prefix)) == 0;
}

stock bool IsWeapon(const char[] classname) {
	return StrStartsWith(classname, "tf_weapon")
		|| StrEqual(classname, "saxxy");
}
