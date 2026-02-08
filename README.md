### First production release of my scripts.

## A. PullLatestReleaseLUA.sh
- This Bash executable should be placed in your LUA folder. Running this script fetches the latest release scripts from this repository. If scripts with the same name already exists within the LUA folder, please take note it will overwrite and replace it.

## 1. vbSniper
- This script builds from skeleton code [Vaccibucks](https://github.com/Spark-Init/LBOX-Adventure/tree/d8bbadf04e8ef9e2aac560cf87fc9493a57fc0fd/VacciBucks) to function as a more automated process for Sniper aimbots in MvM maps during the setup phase.
- Upon detection of joining a new server or leaving a server, script local state variables are reset. MvM auto-ready is disabled. Client will have to manually select Medic, this is to give the option of joining other classes throughout the game.
- As per VacciBucks, medic walks to upgrade station and begins process. Take note the threshold money count is fixed in script to the amount required by Sniper to purchase all essential MvM upgrades. Threshold may not be changed in the in-game console, unlike the original script.
- Once threshold is reached, script sends kill to console and attempts to change to Sniper. **There is a known bug of client being unable to change class at this point in time, neither automatically by script nor manually by manually by player. Working on a fix for next version release. In this soft-lock scenario, only option is to retry in console, and select Sniper class once reconnected.**
- Sniper walks back to Upgrade Station to purchase essential upgrades.
- Once purchased, script sends kill to console.
- Teleporter ESP initiates to find nearest friendly teleporter entrance.
- Sniper auto-walks to teleporter through a pathfinding function weighted between 2 methods, which are predefined vector3 paths, and straight-line path once direct line of sight to teleporter is detected. In the case of multiple friendly teleporter entrances existing, script chooses the closer one.
- Upon touching teleporter entrance, auto-walk is disabled. MvM auto-ready is enabled.
- Throughout the game, client may enable auto-walk to teleporter feature from spawnpoint with the key L.

## 2. autoDC
- This script only works for two cities maps, all 4 missions. Useful for dodging Tour of Duty ticket use.
- Mission is auto-detected by script when joining server, and an integer value matching the map name is chosen from script as a timer duration. This timer duration has been tested to be the ideal duration to abandon a game before the end of the last wave, with a margin of error for safety.
- On the start of the last wave, timer starts counting down.
- Client abandons the game when timer is up. 

## 3. autoCanteen
- This script aims to help the client auto activate canteens when ammo threshold reaches below a fixed value. The script assumes the client has equipped power-up canteen and already purchased ammo refill canteens (which is included in Sniper auto-buy from vbSniper.lua). It is designed to be an "enable-once-and-forget-it" script, working across all MvM maps and missions, and handles its own continuity when leaving and joining MvM servers.
- The script handles both clip and non-clip weapons, ensuring compatibility across all weapons.
- When ammo threshold is reached, script sends console command to use action slot item.
