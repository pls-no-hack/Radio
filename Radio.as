#include "../inc/RelaySay"
#include "Channel"
#include "menus"
#include "songloader"
#include "util"
//#include "target_cdaudio_radio"
#include "ambient_music_radio"
#include "FakeMic"

// BIG TODO:
// - request form should wait for vid info
// - multi channel mic output
// - anarchy mode + tts
// - normalization should be per video, not mixer
// - show hours in hud

// TODO:
// - kick inactive DJs (no song for long time)
// - invite with text message instead of menu
// - show who else is listening/desynced with music sprites or smth
// - alt+tab can run twice or smth
// - let dj rename channel
// - invite cooldowns should use datetime
// - read volume level from ambient_music when scripts are able to read it from the bsp

const string SONG_FILE_PATH = "scripts/plugins/Radio/songs.txt";
const string MUSIC_PACK_PATH = "scripts/plugins/Radio/music_packs.txt";
const string AUTO_DJ_NAME = "Gus";
const float MAX_AUTO_DJ_SONG_LENGTH_MINUTES = 30.0f; // don't play songs longer than this on the auto-dj channel

CCVar@ g_inviteCooldown;
CCVar@ g_requestCooldown;
CCVar@ g_djSwapCooldown;
CCVar@ g_skipSongCooldown;
CCVar@ g_djReserveTime;
CCVar@ g_listenerWaitTime;
CCVar@ g_maxQueue;
CCVar@ g_channelCount;

CClientCommand _radio("radio", "radio commands", @consoleCmd );
CClientCommand _radio2("radiodbg", "radio commands", @consoleCmd );

dictionary g_player_states;
array<Channel> g_channels;
array<Song> g_songs;
FileNode g_root_folder;

array<MusicPack> g_music_packs;
string g_music_pack_update_time;
string g_version_check_file;
string g_version_check_spr;
string g_root_path;

array<int> g_player_lag_status;
uint g_song_id = 1;

dictionary g_level_changers; // don't restart the music for these players on level changes

// Menus need to be defined globally when the plugin is loaded or else paging doesn't work.
// Each player needs their own menu or else paging breaks when someone else opens the menu.
// These also need to be modified directly (not via a local var reference).
array<CTextMenu@> g_menus = {
	null, null, null, null, null, null, null, null,
	null, null, null, null, null, null, null, null,
	null, null, null, null, null, null, null, null,
	null, null, null, null, null, null, null, null,
	null
};



class PlayerState {
	int channel = 0;
	dictionary lastInviteTime; // for invite cooldowns per player and for \everyone
	float lastRequest; // for request cooldowns
	float lastDjToggle; // for cooldown
	float lastSongSkip; // for cooldown
	bool focusHackEnabled = false;
	bool showHud = true;
	bool neverUsedBefore = true;
	bool playAfterFullyLoaded = false; // should start music when this player fully loads
	bool sawUpdateNotification = false; // only show the UPDATE NOW sprite once per map
	bool isDebugging = false;
	
	// text-to-speech settings
	string lang = "en";
	int pitch = 100;
	
	bool shouldInviteCooldown(CBasePlayer@ plr, string id) {
		float inviteTime = -9999;
		if (lastInviteTime.exists(id)) {
			lastInviteTime.get(id, inviteTime);
		}
	
		if (int(id.Find("\\")) != -1) {
			id = id.Replace("\\", "");
		} else {
			CBasePlayer@ target = getPlayerByUniqueId(id);
			if (target !is null) {
				id = target.pev.netname;
			}
		}
		
		return shouldCooldownGeneric(plr, inviteTime, g_inviteCooldown.GetInt(), "inviting " + id + " again");
	}
	
	bool shouldRequestCooldown(CBasePlayer@ plr) {
		return shouldCooldownGeneric(plr, lastRequest, g_djSwapCooldown.GetInt(), "requesting another song");
	}
	
	bool shouldDjToggleCooldown(CBasePlayer@ plr) {
		return shouldCooldownGeneric(plr, lastDjToggle, g_djSwapCooldown.GetInt(), "toggling DJ mode again");
	}
	
	bool shouldSongSkipCooldown(CBasePlayer@ plr) {	
		return shouldCooldownGeneric(plr, lastSongSkip, g_skipSongCooldown.GetInt(), "skipping another song");
	}
	
	bool shouldCooldownGeneric(CBasePlayer@ plr, float lastActionTime, int cooldownTime, string actionDesc) {
		float delta = g_Engine.time - lastActionTime;
		if (delta < cooldownTime) {			
			int waitTime = int((cooldownTime - delta) + 0.99f);
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTTALK, "[Radio] Wait " + waitTime + " seconds before " + actionDesc + ".\n");
			return true;
		}
		
		return false;
	}
	
	bool isRadioListener() {
		return channel >= 0 and g_channels[channel].queue.size() > 0;
	}
}

enum SONG_LOAD_STATES {
	SONG_UNLOADED,
	SONG_LOADING,
	SONG_LOADED
};

class Song {
	string title;
	string artist;
	string path; // file path or youtube url
	uint lengthMillis; // duration in milliseconds
	
	string searchName; // cached version of getName().ToLowercase() for speed
	
	int offset;
	int loadState = SONG_LOADED;
	uint id = 0; // used to relate messages from the voice server to a song in some channel's queue
	string requester;
	
	string getClippedName(int length) {
		string name = getName();
		
		if (int(name.Length()) > length) {
			int sz = (length-4) / 2;
			return name.SubString(0,sz) + " .. " + name.SubString(name.Length()-sz);
		}
		
		return name;
	}
	
	string getName() const {
		if (artist.Length() == 0) {
			return title.Length() > 0 ? title : path;
		}
		return artist + " - " + title;
	}
	
	string getMp3PlayCommand() {
		string mp3 = path; // don't modify the original var
		return "mp3 play " + g_root_path + mp3.Replace(".mp3", "");
	}
}

class FileNode {
	string name;
	Song@ file = null;
	array<FileNode@> children;
}

class MusicPack {
	string link;
	string desc;
	
	string getSimpleDesc() {
		string simple = desc;
		return simple.Replace("\\r", "").Replace("\\w", "").Replace("\\d", "").Replace("\n", " ");
	}
}

enum LAG_STATES {
	LAG_NONE,
	LAG_SEVERE_MSG,
	LAG_JOINING
}


void PluginInit() {
	g_Module.ScriptInfo.SetAuthor( "w00tguy" );
	g_Module.ScriptInfo.SetContactInfo( "https://github.com/wootguy" );
	
	g_Hooks.RegisterHook(Hooks::Player::ClientPutInServer, @ClientJoin);
	g_Hooks.RegisterHook(Hooks::Player::ClientDisconnect, @ClientLeave);
	g_Hooks.RegisterHook(Hooks::Player::ClientSay, @ClientSay);
	g_Hooks.RegisterHook(Hooks::Game::MapChange, @MapChange);
	
	@g_inviteCooldown = CCVar("inviteCooldown", 600, "Radio invite cooldown", ConCommandFlag::AdminOnly);
	@g_requestCooldown = CCVar("requestCooldown", 300, "Song request cooldown", ConCommandFlag::AdminOnly);
	@g_djSwapCooldown = CCVar("djSwapCooldown", 5, "DJ mode toggle cooldown", ConCommandFlag::AdminOnly);
	@g_skipSongCooldown = CCVar("skipSongCooldown", 10, "DJ mode toggle cooldown", ConCommandFlag::AdminOnly);
	@g_djReserveTime = CCVar("djReserveTime", 240, "Time to reserve DJ slots after level change", ConCommandFlag::AdminOnly);
	@g_listenerWaitTime = CCVar("listenerWaitTime", 30, "Time to wait for listeners before starting new music after a map change", ConCommandFlag::AdminOnly);
	@g_maxQueue = CCVar("maxQueue", 8, "Max songs that can be queued", ConCommandFlag::AdminOnly);
	@g_channelCount = CCVar("channelCount", 3, "Number of available channels", ConCommandFlag::AdminOnly);
	
	g_channels.resize(g_channelCount.GetInt());
	
	for (uint i = 0; i < g_channels.size(); i++) {
		g_channels[i].name = "Channel " + (i+1);
		g_channels[i].id = i;
		
		if (i == g_channels.size()-1) {
			//g_channels[i].autoDj = true;
		}
	}
	
	for ( int i = 1; i <= g_Engine.maxClients; i++ )
	{
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (plr is null or !plr.IsConnected()) {
			continue;
		}
		
		g_level_changers[getPlayerUniqueId(plr)] = true;
	}
	
	g_root_folder.name = g_root_path;
	loadSongs();
	loadMusicPackInfo();
	
	g_Scheduler.SetInterval("radioThink", 0.5f, -1);
	g_Scheduler.SetInterval("radioResumeHack", 0.05f, -1);
	
	g_voice_ent_idx = getEmptyPlayerSlotIdx();
	load_samples();
	play_samples(false);
	
	g_player_lag_status.resize(33);
	
	send_voice_server_message("Radio\\en\\100\\.mstop");
}

void MapInit() {
	g_Game.PrecacheGeneric(g_root_path + g_version_check_file);
	
	g_Game.PrecacheModel(g_root_path + g_version_check_spr);
	
	loadSongs();
	loadMusicPackInfo();
	
	// Reset temporary vars
	array<string>@ states = g_player_states.getKeys();
	for (uint i = 0; i < states.length(); i++)
	{
		PlayerState@ state = cast< PlayerState@ >(g_player_states[states[i]]);
		state.lastInviteTime.clear();
		state.lastRequest = -9999;
		state.lastDjToggle = -9999;
		state.lastSongSkip = -9999;
		state.sawUpdateNotification = false;
	}
}

int g_replaced_cdaudio = 0;
int g_replaced_music = 0;
void MapActivate() {
	//g_CustomEntityFuncs.RegisterCustomEntity( "target_cdaudio_radio", "target_cdaudio_radio" );
	//g_CustomEntityFuncs.RegisterCustomEntity( "AmbientMusicRadio::ambient_music_radio", "ambient_music_radio" );
	
	g_replaced_cdaudio = 0;
	g_replaced_music = 0;
	
	CBaseEntity@ cdaudio = null;
	do {
		@cdaudio = g_EntityFuncs.FindEntityByClassname(cdaudio, "target_cdaudio"); 

		if (cdaudio !is null)
		{
			dictionary keys;
			keys["origin"] = cdaudio.pev.origin.ToString();
			keys["targetname"] = string(cdaudio.pev.targetname);
			keys["health"] =  "" + cdaudio.pev.health;
			CBaseEntity@ newent = g_EntityFuncs.CreateEntity("target_cdaudio_radio", keys, true);
		
			g_EntityFuncs.Remove(cdaudio);
			g_replaced_cdaudio++;
		}
	} while (cdaudio !is null);
	
	println("[Radio] Replaced " + g_replaced_cdaudio + " trigger_cdaudio entities with trigger_cdaudio_radio");
	
	CBaseEntity@ music = null;
	do {
		@music = g_EntityFuncs.FindEntityByClassname(music, "ambient_music"); 

		if (music !is null)
		{
			dictionary keys;
			keys["origin"] = music.pev.origin.ToString();
			keys["targetname"] = string(music.pev.targetname);
			keys["message"] =  "" + music.pev.message;
			keys["spawnflags"] =  "" + music.pev.spawnflags;
			//keys["volume"] =  "" + music.pev.volume; // Can't do this, so just assuming it's always max volume
			CBaseEntity@ newent = g_EntityFuncs.CreateEntity("ambient_music_radio", keys, true);
		
			g_EntityFuncs.Remove(music);
			g_replaced_music++;
		}
	} while (music !is null);
	
	println("[Radio] Replaced " + g_replaced_music + " ambient_music entities with ambient_music_radio");
}

HookReturnCode MapChange() {
	for ( int i = 1; i <= g_Engine.maxClients; i++ )
	{
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (plr is null or !plr.IsConnected()) {
			continue;
		}

		PlayerState@ state = getPlayerState(plr);
		if (state.channel >= 0) {
			// This prevents music stopping during the map change.
			// Possibly not nice to do this. Someone might have customized the setting for some reason.
			clientCommand(plr, "mp3fadetime 999999");
		}
	}
	
	// wait before saving connected players in case classic mode is restarting the map
	if (g_Engine.time > 5) {
		for (uint i = 0; i < g_channels.size(); i++) {
			g_channels[i].rememberListeners();
		}
	}
	
	for (uint i = 0; i < 33; i++) {
		g_player_lag_status[i] = LAG_JOINING;
	}

	return HOOK_CONTINUE;
}

HookReturnCode ClientJoin(CBasePlayer@ plr) {
	PlayerState@ state = getPlayerState(plr);
	string id = getPlayerUniqueId(plr);
	
	if (!g_level_changers.exists(id)) {
		if (state.channel >= 0) {
			state.playAfterFullyLoaded = true;
		}
		
		g_level_changers[id] = true;
	} else {
		if (!state.isRadioListener()) // start map music instead of radio
			state.playAfterFullyLoaded = true;
	}
	
	// always doing this in case someone left during a level change, preventing the value from resetting
	// TODO: actually can't do this because it cranks volume up if a fadeout is currently active
	//g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "[Radio] Your 'mp3fadetime' setting was reset to 2.\n");
	//clientCommand(plr, "mp3fadetime 2");
	
	g_voice_ent_idx = getEmptyPlayerSlotIdx();
	
	return HOOK_CONTINUE;
}

HookReturnCode ClientLeave(CBasePlayer@ plr) {
	PlayerState@ state = getPlayerState(plr);
	
	// TODO: this won't trigger for players who leave during level changes
	g_level_changers.delete(getPlayerUniqueId(plr));
	
	if (state.channel >= 0) {
		if (g_channels[state.channel].currentDj == getPlayerUniqueId(plr)) {
			g_channels[state.channel].currentDj = "";
		}
	}
	
	return HOOK_CONTINUE;
}

HookReturnCode ClientSay( SayParameters@ pParams ) {
	CBasePlayer@ plr = pParams.GetPlayer();
	const CCommand@ args = pParams.GetArguments();
	
	if (doCommand(plr, args, false)) {
		pParams.ShouldHide = true;
	}
	
	return HOOK_CONTINUE;
}

array<Song@> searchSongs(string searchStr) {
	array<Song@> results;
	searchStr = searchStr.ToLowercase();
	
	for (uint i = 0; i < g_songs.size(); i++) {
		Song@ song = g_songs[i];
		if (int(song.searchName.Find(searchStr)) != -1) {
			results.insertLast(song);
		}
	}
	
	if (results.size() > 0) {
		results.sort(function(a,b) { return a.searchName < b.searchName; });
	}
	
	return results;
}

void radioThink() {	
	loadCrossPluginLoadState();
	
	for (uint i = 0; i < g_channels.size(); i++) {
		g_channels[i].think();
	}
	
	for ( int i = 1; i <= g_Engine.maxClients; i++ )
	{
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (plr is null or !plr.IsConnected()) {
			continue;
		}
		
		PlayerState@ state = getPlayerState(plr);
		
		if (state.playAfterFullyLoaded and g_player_lag_status[plr.entindex()] == LAG_NONE) {
			println("Playing music for fully loaded player: " + plr.pev.netname);
			state.playAfterFullyLoaded = false;
			
			if (state.isRadioListener()) {
				Song@ song = g_channels[state.channel].queue[0];
				clientCommand(plr, song.getMp3PlayCommand());
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTTALK, "[Radio] Now playing: " + song.getName() + "\n");
			} else {
				AmbientMusicRadio::toggleMapMusic(plr, true);
			}
		}

		if (state.isRadioListener() and state.showHud) {
			g_channels[state.channel].updateHud(plr, state);
		}
	}
}

void radioResumeHack() {
	// spam the "cd resume" command to stop the music pausing when the game window loses focus
	// TODO: only do this when not pushing buttons
	
	for ( int i = 1; i <= g_Engine.maxClients; i++ )
	{
		CBasePlayer@ plr = g_PlayerFuncs.FindPlayerByIndex(i);
		
		if (plr is null or !plr.IsConnected()) {
			continue;
		}
		
		PlayerState@ state = getPlayerState(plr);
		if (state.focusHackEnabled and state.channel >= 0) {
			Channel@ chan = g_channels[state.channel];
		
			clientCommand(plr, "cd resume", MSG_ONE_UNRELIABLE);
		}
	}
}

void loadCrossPluginLoadState() {
	CBaseEntity@ afkEnt = g_EntityFuncs.FindEntityByTargetname(null, "PlayerStatusPlugin");
	
	if (afkEnt is null) {
		return;
	}
	
	CustomKeyvalues@ customKeys = afkEnt.GetCustomKeyvalues();
	
	for ( int i = 1; i <= g_Engine.maxClients; i++ )
	{
		CustomKeyvalue key = customKeys.GetKeyvalue("$i_state" + i);
		if (key.Exists()) {
			g_player_lag_status[i] = key.GetInteger();
		}
	}
}

void showConsoleHelp(CBasePlayer@ plr, bool showChatMessage) {
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '------------------------------ Radio Commands ------------------------------\n\n');
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, 'Type ".radio" to open the radio menu.\n\n');
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, 'Type ".radio search <search terms>" to search for songs to play.\n\n');
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, 'Type ".radio faq" for answers to frequently asked questions.\n\n');
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, 'Type ".radio hud" to toggle the radio HUD.\n\n');
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, 'Type ".radio list" to show who\'s listening.\n\n');
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, 'Type ".radio pausefix" to toggle the music-pause fix.\n');
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '    This prevents the music pausing when the game window loses focus (alt+tab).\n');
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '    In order for this to work you need to also set "cl_filterstuffcmd 0" in the console.\n');
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '    DANGER! DANGER! YOU DO THIS AT YOUR OWN RISK!\n');
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '    DISABLING FILTERSTUFF ALLOWS THE SERVER TO RUN ***ANY*** COMMAND IN YOUR CONSOLE!!1!!\n');
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '    In the past this has been abused for things like rebinding your jump button to crash the game.\n');
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '    Only disable cl_filterstuffcmd on servers you trust. Add "cl_filterstuffcmd 1" to userconfig.cfg\n');
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '    so you don\'t have to remember to turn it back on.\n\n');
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, '\n--------------------------------------------------------------------------\n');

	if (showChatMessage) {
		g_PlayerFuncs.ClientPrint(plr, HUD_PRINTTALK, '[Radio] Help info sent to your console.\n');
	}
}

void showConsoleFaq(CBasePlayer@ plr, bool showChatMessage) {
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "------------------------------ Radio FAQ ------------------------------\n\n");
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "Can't hear music?\n");
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "  1) Download and install the latest music pack\n");
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "  2) Pick \"Test installation\" in the Help menu to test your installation\n");
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "  3) Check that your music volume isn't too low in Options -> Audio\n");
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "  4) Pick \"Restart music\" in the Help menu and it should start working\n");
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "  You will see 'Could not find music file' errors in the console if you didn't install properly.\n");
	
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "\nSong changing too soon?\n");
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "  Your music playback was desynced from the server. This happens when:\n");
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "    - You joined a channel after the music started\n");
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "    - You alt-tabbed out of the game (music pauses when the game isn't in focus)\n");
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "  To fix the desync, just wait for the next song to start and keep the game window in focus.\n");
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "  You might want to try the pausefix command if this happens a lot (see .radio help).\n");
	
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "\nMusic pack download links (choose which quality you want):\n");
	string stringu = "";
	for (uint i = 0; i < g_music_packs.size(); i++) {		
		string desc = g_music_packs[i].getSimpleDesc();
		string link = g_music_packs[i].link;
		
		g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "  - " + desc + "\n");
		g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "    " + link + "\n\n");
	}
	
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "Music pack last updated:\n" + g_music_pack_update_time + "\n");
	g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "\n------------------------------------------------------------------------\n");

	if (showChatMessage) {
		g_PlayerFuncs.ClientPrint(plr, HUD_PRINTTALK, "[Radio] FAQ sent to your console.\n");
	}
}

bool doCommand(CBasePlayer@ plr, const CCommand@ args, bool inConsole) {
	bool isAdmin = g_PlayerFuncs.AdminLevel(plr) >= ADMIN_YES;
	PlayerState@ state = getPlayerState(plr);
	
	if (args.ArgC() > 0 && args[0] == ".radiodbg") {
		g_PlayerFuncs.ClientPrint(plr, HUD_PRINTTALK, "[Radio] replaced " + g_replaced_cdaudio + " cd audios.\n");
		return true;
	}
	
	string lowerArg = args[0].ToLowercase();
	
	if (args.ArgC() > 0 && args[0] == ".radio") {
	
		if (args.ArgC() == 1) {
			bool isEnabled = state.channel >= 0;
	
			if (isEnabled) {
				openMenuRadio(EHandle(plr));
			} else {
				openMenuChannelSelect(EHandle(plr));
			}
		}
		else if (args.ArgC() > 1 and args[1] == "hud") {
			state.showHud = !state.showHud;
			
			if (args.ArgC() > 2) {
				state.showHud = atoi(args[2]) != 0;
			}
			
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTTALK, "[Radio] HUD " + (state.showHud ? "enabled" : "disabled") + ".\n");
		}
		else if (args.ArgC() > 1 and args[1] == "pausefix") {
			state.focusHackEnabled = !state.focusHackEnabled;
			
			if (args.ArgC() > 2) {
				state.focusHackEnabled = atoi(args[2]) != 0;
			}
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTTALK, "[Radio] Music-pause fix " + (state.focusHackEnabled ? "enabled" : "disabled") + ".\n");
		}
		else if (args.ArgC() > 1 and args[1] == "list") {
			for (uint i = 0; i < g_channels.size(); i++) {
				Channel@ chan = g_channels[i];
				array<CBasePlayer@> listeners = chan.getChannelListeners();
				
				string title = chan.name;
				CBasePlayer@ dj = chan.getDj();
				
				title += dj !is null ? "  (DJ: " + dj.pev.netname + ")" : "";
				
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "\n\n" + title + "\n------------------");
				for (uint k = 0; k < listeners.size(); k++) {
					uint pos = (k+1);
					string spos = pos;
					if (pos < 10) {
						spos = " " + spos;
					}
					
					g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "\n" + spos + ") " + listeners[k].pev.netname);
				}
				
				if (listeners.size() == 0) {
					g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "\n(empty)");
				}
			}
			
			g_PlayerFuncs.ClientPrint(plr, HUD_PRINTCONSOLE, "\n\n");
		}
		else if (args.ArgC() > 1 and args[1] == "help") {
			showConsoleHelp(plr, !inConsole);
		}
		else if (args.ArgC() > 1 and args[1] == "faq") {
			showConsoleFaq(plr, !inConsole);
		}
		else if (args.ArgC() > 2 and args[1] == "search") {
			string searchStr = args[2];
			for (int i = 3; i < args.ArgC(); i++) {
				searchStr += " " + args[i];
			}
			openMenuSearch(EHandle(plr), searchStr, 0);
		} else if (args.ArgC() > 1 and args[1] == "debug") {		
			state.isDebugging = !state.isDebugging;
			
			if (state.isDebugging) {
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTTALK, "[Radio] Debug mode ON.\n");
			} else {
				g_PlayerFuncs.ClientPrint(plr, HUD_PRINTTALK, "[Radio] Debug mode OFF.\n");
			}
		}
		
		return true;
	} else if (lowerArg.Find("https://www.youtube.com") == 0 || lowerArg.Find("https://youtu.be") == 0) {	
	
		if (state.channel != -1) {			
			Channel@ chan = @g_channels[state.channel];
			bool canDj = chan.canDj(plr);
			
			Song song;
			song.path = args[0];
			song.loadState = SONG_UNLOADED;
			song.id = g_song_id;
			song.requester = plr.pev.netname;
			
			g_song_id += 1;
			
			if (!canDj)  {
				if (int(chan.queue.size()) >= g_maxQueue.GetInt()) {
					g_PlayerFuncs.ClientPrint(plr, HUD_PRINTTALK, "[Radio] Can't request now. The queue is full.\n");
				}
				else if (!state.shouldRequestCooldown(plr)) {
					chan.announce("" + plr.pev.netname + " requested: " + song.path);
					openMenuSongRequest(EHandle(chan.getDj()), plr.pev.netname, song.path, song.path);
				}
			}
			else {			
				chan.queueSong(plr, song);
			}
			
			return true;
		}
	}
	
	return false;
}

void consoleCmd( const CCommand@ args ) {
	CBasePlayer@ plr = g_ConCommandSystem.GetCurrentPlayer();
	doCommand(plr, args, true);
}
