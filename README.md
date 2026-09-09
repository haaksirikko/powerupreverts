# Mannpower Reverts

## NOTE! This is a beta. Expect bugs

A SourceMod plugin that attempts to revert various features of the Mannpower game mode in Team Fortress 2.
At the moment, it targets to revert the nerfs made in and after the [May 11, 2016 patch](https://wiki.teamfortress.com/wiki/May_11,_2016_Patch), when team switching was outright disabled in Mannpower.
Subsequent changes to Mannpower have almost always been nerfs to mechanics in the mode, especially the changes made in [October](https://wiki.teamfortress.com/wiki/October_1,_2020_Patch) and [November of 2020](https://wiki.teamfortress.com/wiki/November_5,_2020_Patch).

Dependencies:

- 32-bit server
- [TF2Attributes](https://github.com/FlaminSarge/tf2attributes)
- [TF2Utils](https://github.com/nosoop/SM-TFUtils)
- [Source Scramble](https://github.com/nosoop/SMExt-SourceScramble)

ConVars:
- `sm_powerupreverts_enable` - Enable or disable the plugin. (default: 1)
  - 0: Disable
  - 1: Enable, powerup carriers have vanilla penalties
  - 2: Enable, powerup carriers have no penalties
- `sm_powerupreverts_crits` - Enable crits in Mannpower (default: 0)
- `sm_powerupreverts_dominant` - Enable dominant state in Mannpower (default: 1)
- `sm_powerupreverts_imbalance_swap` - Enable imbalance swap in Mannpower (default: 0)
