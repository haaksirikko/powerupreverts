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
#define PLUGIN_DESC "Reverts Mannpower changes made after May 2016"
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

bool g_bPowerupRevertsEnabled;
int g_entMannpowerLogicEntity = -1;

ConVar sm_powerup_reverts_enable;

ConVar tf_powerup_mode;
ConVar tf_powerup_mode_imbalance_consecutive_min_players;
ConVar tf_powerup_mode_dominant_multiplier;
ConVar tf_powerup_mode_killcount_timer_length;
ConVar tf_weapon_criticals;

DynamicHook dhook_CTFWeaponBaseMelee_DoMeleeDamage;
DynamicHook dhook_CTFSniperRifle_GetProjectileDamage;

DynamicDetour detour_CTFPlayer_StateEnterACTIVE;
DynamicDetour detour_CTFGameRules_SetupOnRoundStart;

MemoryPatch patch_HeavyGrappleJumpBoost;
bool g_bHeavyGrapplePatchEnabled;

public void OnPluginStart() {
	sm_powerup_reverts_enable = CreateConVar("sm_powerup_reverts_enable", "1", "Toggle Mannpower Reverts", _, true, 0.0, true, 1.0);
	sm_powerup_reverts_enable.AddChangeHook(TogglePowerupReverts);

	tf_powerup_mode = FindConVar("tf_powerup_mode");
	tf_powerup_mode_imbalance_consecutive_min_players = FindConVar("tf_powerup_mode_imbalance_consecutive_min_players");
	tf_powerup_mode_dominant_multiplier = FindConVar("tf_powerup_mode_dominant_multiplier");
	tf_powerup_mode_killcount_timer_length = FindConVar("tf_powerup_mode_killcount_timer_length");
	tf_weapon_criticals = FindConVar("tf_weapon_criticals");

	tf_powerup_mode.AddChangeHook(TogglePowerupReverts);

	GameData conf = new GameData("powerupreverts");
	if (conf == null) SetFailState("Failed to load powerupreverts gamedata");

	dhook_CTFWeaponBaseMelee_DoMeleeDamage = DynamicHook.FromConf(conf, "CTFWeaponBaseMelee::DoMeleeDamage");
	dhook_CTFSniperRifle_GetProjectileDamage = DynamicHook.FromConf(conf, "CTFSniperRifle::GetProjectileDamage");
	detour_CTFPlayer_StateEnterACTIVE = DynamicDetour.FromConf(conf, "CTFPlayer::StateEnterACTIVE");
	detour_CTFGameRules_SetupOnRoundStart = DynamicDetour.FromConf(conf, "CTFGameRules::SetupOnRoundStart");

	patch_HeavyGrappleJumpBoost = MemoryPatch.CreateFromConf(conf, "CTFGameMovement::CheckJumpButton_HeavyGrappleJumpBoost");
	if (patch_HeavyGrappleJumpBoost == null || !patch_HeavyGrappleJumpBoost.Validate()) {
		LogError("Failed to create CTFGameMovement::CheckJumpButton_HeavyGrappleJumpBoost memory patch");
		patch_HeavyGrappleJumpBoost = null;
	}
	delete conf;

	#define VALIDATE_HANDLE(%1) if (%1 == null) SetFailState("Failed to hook " ... #%1)

	VALIDATE_HANDLE(dhook_CTFWeaponBaseMelee_DoMeleeDamage);
	VALIDATE_HANDLE(dhook_CTFSniperRifle_GetProjectileDamage);
	VALIDATE_HANDLE(detour_CTFPlayer_StateEnterACTIVE);
	VALIDATE_HANDLE(detour_CTFGameRules_SetupOnRoundStart);

	detour_CTFPlayer_StateEnterACTIVE.Enable(Hook_Pre, DetourCallback_CTFPlayer_StateEnterACTIVE_Pre);
	detour_CTFPlayer_StateEnterACTIVE.Enable(Hook_Post, DetourCallback_CTFPlayer_StateEnterACTIVE_Post);
	detour_CTFGameRules_SetupOnRoundStart.Enable(Hook_Pre, DetourCallback_CTFGameRules_SetupOnRoundStart_Pre);
	detour_CTFGameRules_SetupOnRoundStart.Enable(Hook_Post, DetourCallback_CTFGameRules_SetupOnRoundStart_Post);

	for (int i = 1; i <= MaxClients; i++) {
		//if (IsClientConnected(i)) OnClientConnected(i);
		if (IsClientInGame(i)) OnClientPutInServer(i);
	}

	LogMessage(PLUGIN_NAME ... " has loaded.");
}

public void OnPluginEnd() {
	ApplyHeavyGrappleJumpBoost(false);
	ResetPowerupModeProp();
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
		} else {
			LogMessage("No Mannpower logic entity detected, disabling Mannpower Reverts");
			DisablePowerupReverts();
		}
	} else {
		DisablePowerupReverts();
	}
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

	if (frame % 66 == 0) {
		if (IsRevertedPowerupMode()) {
			// Set these to high values such that they practically never happen
			tf_powerup_mode_imbalance_consecutive_min_players.IntValue = 999;
			tf_powerup_mode_dominant_multiplier.IntValue = 999;
			tf_powerup_mode_killcount_timer_length.IntValue = 999;

			// Disable crits
			tf_weapon_criticals.BoolValue = false;

			ZeroPowerupModeProp();
		}
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
}
public void OnClientDisconnect_Post(int client) {
	ZeroPowerupModeProp();
}

public void OnEntityCreated(int entity, const char[] class) {
	if (entity < 0 || entity >= 2048) return;

	if (strncmp(class, "obj_", sizeof("obj_")) == 0) {
		SDKHook(entity, SDKHook_OnTakeDamage, SDKHookCB_OnTakeDamage_Building);
	}
	else if (strncmp(class, "tf_weapon_sniperrifle", sizeof("tf_weapon_sniperrifle")) == 0) {
		dhook_CTFSniperRifle_GetProjectileDamage.HookEntity(Hook_Pre, entity, DHookCallback_CTFSniperRifle_GetProjectileDamage_Pre);
		dhook_CTFSniperRifle_GetProjectileDamage.HookEntity(Hook_Post, entity, DHookCallback_CTFSniperRifle_GetProjectileDamage_Post);
	}
	else if (StrEqual(class, "item_powerup_rune_temp")) {
		SDKHook(entity, SDKHook_Spawn, SDKHookCB_Spawn);
		SDKHook(entity, SDKHook_SpawnPost, SDKHookCB_SpawnPost);
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
	ZeroPowerupModeProp();

	Action returnValue = Plugin_Continue;

	if (
		IsRevertedPowerupMode() &&
		attacker >= 1 && attacker <= MaxClients
	) {
		if (
			GetCarryingRuneType(attacker) == RUNE_STRENGTH ||
			TF2_IsPlayerInCondition(attacker, TFCond_CritRuneTemp)
		) {
			damage *= 2.0;
			returnValue = Plugin_Changed;
		}

		if (GetCarryingRuneType(attacker) == RUNE_KNOCKOUT) {
			damage *= 4.0;
			returnValue = Plugin_Changed;
		}

		if (
			GetCarryingRuneType(attacker) == RUNE_VAMPIRE &&
			damage > 0.0
		) {
			TF2Util_TakeHealth(attacker, damage);
		}
	}
	return returnValue;
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
			dhook_CTFWeaponBaseMelee_DoMeleeDamage.HookEntity(Hook_Pre, weapon, DHookCallback_CTFWeaponBaseMelee_DoMeleeDamage_Pre);
			dhook_CTFWeaponBaseMelee_DoMeleeDamage.HookEntity(Hook_Post, weapon, DHookCallback_CTFWeaponBaseMelee_DoMeleeDamage_Post);
		}
	}
}

// Melee damage
MRESReturn DHookCallback_CTFWeaponBaseMelee_DoMeleeDamage_Pre(int entity, DHookParam parameters) {
	ResetPowerupModeProp();
	return MRES_Ignored;
}
MRESReturn DHookCallback_CTFWeaponBaseMelee_DoMeleeDamage_Post(int entity, DHookParam parameters) {
	ZeroPowerupModeProp();
	return MRES_Ignored;
}

// Sniper rifle precision damage bonus
MRESReturn DHookCallback_CTFSniperRifle_GetProjectileDamage_Pre(int entity, DHookReturn returnValue) {
	ResetPowerupModeProp();
	return MRES_Ignored;
}
MRESReturn DHookCallback_CTFSniperRifle_GetProjectileDamage_Post(int entity, DHookReturn returnValue) {
	ZeroPowerupModeProp();
	return MRES_Ignored;
}

// Handles Mannpower regen application
MRESReturn DetourCallback_CTFPlayer_StateEnterACTIVE_Pre(int client) {
	ResetPowerupModeProp();
	return MRES_Ignored;
}
MRESReturn DetourCallback_CTFPlayer_StateEnterACTIVE_Post(int client) {
	ZeroPowerupModeProp();
	return MRES_Ignored;
}

// Handles Mannpower logic on round start (spawns runes)
MRESReturn DetourCallback_CTFGameRules_SetupOnRoundStart_Pre(Address _this) {
	ResetPowerupModeProp();
	return MRES_Ignored;
}
MRESReturn DetourCallback_CTFGameRules_SetupOnRoundStart_Post(Address _this) {
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

TFCond GetConditionFromRuneType( RuneTypes_t rt )
{
	switch ( rt )
	{ 
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
	default:
		LogError("Unexpected rune_type rt (%d) in GetConditionFromRuneType", rt);	
	}

	return view_as<TFCond>(-1);
}

static RuneTypes_t GetCarryingRuneType(int _this)
{
    RuneTypes_t retVal = RUNE_NONE;
    for (RuneTypes_t i = view_as<RuneTypes_t>(0); i < RUNE_TYPES_MAX; ++i)
    {
        if (TF2_IsPlayerInCondition(_this, view_as<TFCond>(GetConditionFromRuneType(i))))
        {
            retVal = i;
            break;
        }
    }
    return retVal;
}
