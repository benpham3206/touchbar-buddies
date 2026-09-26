# Touch Bar Buddies

**Clawd and the Codex pet live in your MacBook Pro's Touch Bar.** They sleep while Claude and Codex are closed.
They type on tiny laptops while your agents work, and they play catch, throw paper planes and visit each other.

![The whole Touch Bar: the buddies wake up, wave, play catch, and Clawd drives over for a high-five](docs/touchbar.gif)

Up close (Codex's corner on the left, Clawd's on the right):

![Close-up of the two buddies](docs/closeup.gif)

Your Touch Bar's Control Strip is replaced by a faithful copy of itself: your buttons, in your order, and
they work the same way. (A few it doesn't copy yet, like Siri or Screenshot, are left out.) The buddies
live in the gaps.

- **Codex** (left) is awake while the ChatGPT app or the `codex` CLI is open.
- **Clawd** (right), Claude Code's pixel crab, is awake while the Claude app or the `claude` CLI is open.
- Tap a sleeping buddy to open its app, straight on the coding screen.
- They type while their agent works, celebrate when it's done, and cheer each other on.

The app never reads your chats. It only looks at which apps are running and how busy they are. The only
thing it ever downloads is Clawd's animations from claude.ai, once.

## What you need

- A **MacBook Pro with a Touch Bar** running **macOS 12 Monterey or newer**.
- Apple's **Command Line Tools**, which the installer uses to build the app. If you don't have them, the
  installer tells you to run `xcode-select --install`.
- The **Claude** desktop app and/or the **ChatGPT** desktop app with Codex. The buddies wake up when these
  apps (or the `claude` / `codex` command-line tools) are open, and part of their artwork comes from the
  apps (see [First launch](#first-launch)).

## Install

Open **Terminal** (press ⌘-Space and type "Terminal"), paste this line, and press Return:

```sh
curl -fsSL https://raw.githubusercontent.com/benpham3206/touchbar-buddies/main/install.sh | zsh
```

It downloads the source code to a folder called **`touchbar-buddies`** in your home folder, builds the
app right on your Mac (about a minute), puts it in `~/Applications`, and starts it now and every time you
log in. Because it's built on your Mac, macOS has no "unidentified developer" warnings to show. The
folder is yours to change, too: see [Make it yours](#make-it-yours-with-claude-code-or-codex).

To update later, paste the same line again. Your own changes are kept. If they clash with the update,
the update is skipped.

<details>
<summary><b>Or: download the ready-made app (no Terminal)</b></summary>

1. Download `TouchBarBuddies.zip` from the
   [Releases page](https://github.com/benpham3206/touchbar-buddies/releases) and double-click it to unzip.
2. Drag `TouchBarBuddies.app` into your Applications folder and open it.
3. macOS will refuse the first time, because the app isn't notarized by Apple. Open **System Settings >
   Privacy & Security**, scroll down, and click **Open Anyway**. (On macOS 14 or older you can also
   Control-click the app and choose **Open**.)
4. To start it at every login, click the Clawd icon in the menu bar and choose **Open at Login**.

This version can't be changed with Claude Code or Codex. For that, use the one-line install.
</details>

## First launch

The characters belong to Anthropic and OpenAI, so this project doesn't include them. The first time the
app starts, it makes its own copy on your Mac, which takes a few seconds:

- **Clawd** comes from the public animations on claude.ai (the same GIFs the Claude app shows), plus the
  laptop animation inside your Claude app.
- **Codex** comes from the pet sprite sheet inside your ChatGPT app.

The copy stays in `~/Library/Application Support/TouchBarBuddies` and is never shared. Without the
ChatGPT app, Codex stays hidden. Without the Claude app, Clawd still comes, but he scuttles instead of
typing on a laptop. If you install an app later, choose **Rebuild Sprites** from the menu bar icon.

## Using it

- **Tap a sleeping buddy** to open its app on the coding screen. With the optional permission below,
  Codex's window also moves to the left half of the screen and Claude's to the right.
- **Tap an awake buddy** to bring its app to the front, as it is (no new session), and get a hop and a heart.
- While Claude or Codex is **working**, its buddy types away on a laptop and the other one cheers it on.
  When **both** are working, every so often one gets up and crosses the bar to hand the other part of its work
  in person; when that agent finishes, it travels back to deliver the result.
  When the work is done, there's confetti.
- Every so often they **play together**: catch, paper planes, `{}` and `✻` packets, echo hops,
  peek-a-boo, and visits across the bar by race car, cloud or on foot (Codex sprints, sneaks up on Clawd,
  runs laps and sometimes trips).
- The **buttons** work like the real ones. Tap brightness or volume for a slider, or press one and slide
  for a quick change. Hold a keyboard-light button to keep changing it.
- The **Clawd icon in the menu bar** has Play Together (or pick a game under Play), Visits Across the Bar,
  "pretend" switches to see the working animations, Open at Login, Refresh Touch Bar, Rebuild Sprites and Quit.

### Optional: window tiling and media keys

The **Accessibility** permission lets the app arrange Claude and ChatGPT side by side, and makes the
⏮ ⏯ ⏭ buttons act exactly like the hardware keys. Choose **Allow Window Tiling & Media Keys…** from the
menu bar icon, or add TouchBarBuddies under **System Settings > Privacy & Security > Accessibility**.
The app works fine without it.

Every build gets a new signature, so after you update or rebuild, macOS forgets that permission. Remove
TouchBarBuddies from the Accessibility list and add it again.

### Easter eggs

There are a few. We won't spoil them, but… what happens if you poke a buddy a few times in a row? What
about the ⏯ key? And have you tried holding both buddies at once…? Or run Codex at **ultra** effort, or say
**ultracode** to Claude Code, and keep an eye on the Touch Bar.

## Make it yours with Claude Code or Codex

The `~/touchbar-buddies` folder is a normal project folder. Open it in **Claude Code** or **Codex** and
ask for what you want in plain words. For example:

- *"Add an animation where Clawd and Codex high-five when Claude finishes a task."*
- *"When I press play/pause, make Codex dance instead of hopping."*
- *"Add a new game where they pass a coffee cup back and forth."*
- *"Make Clawd blow a bubble now and then while he's waiting."*
- *"Give them little Santa hats in December."*

The folder comes with instructions for AI agents ([AGENTS.md](AGENTS.md), which Claude Code also reads
through [CLAUDE.md](CLAUDE.md)). They explain how the app works and how to check a new animation, so you
don't need to know Swift. Your agent can **watch its own work without a Touch Bar**: `./tbb render`
draws the bar into an image. Then it puts the new version on your Touch Bar with `./tbb run`.

The helper script, if you want to drive it yourself (run it inside the folder):

```sh
./tbb run                  # build and restart the app with your changes
./tbb send toss            # play something right now (./tbb commands lists them all)
./tbb render toss.gif --do toss --seconds 10   # record the Touch Bar to a GIF, no Touch Bar needed
./tbb logs                 # follow the app's log
./install.sh               # keep your version: it starts at every login
```

## Something wrong?

Run `./tbb doctor` inside `~/touchbar-buddies` and paste the output into an issue, or ask Claude Code /
Codex to run it and fix what it finds. It lists what's installed, the permission state, and any stutters
the app logged.

## Uninstall

```sh
zsh ~/touchbar-buddies/uninstall.sh
```

This puts the normal Control Strip back and moves the app, its login item, its sprites and its log to
the Trash. Claude and ChatGPT aren't touched. The `~/touchbar-buddies` folder stays, in case you
changed something; move it to the Trash yourself if you like.

If you installed the zip instead, choose **Quit** from the menu bar icon (turn off **Open at Login**
first), then move the app and `~/Library/Application Support/TouchBarBuddies` to the Trash.

## Troubleshooting

| Problem | Try this |
|---|---|
| The Touch Bar still shows the normal buttons | Look for the Clawd icon in the menu bar. If it's there, choose **Refresh Touch Bar**. If not, start the app: `open ~/Applications/TouchBarBuddies.app`. |
| A buddy is missing | Choose **Rebuild Sprites** from the menu bar icon. To see what's missing, run `./tbb sprites` in the folder: Clawd needs an internet connection once, and Codex needs the ChatGPT app. |
| Clawd scuttles instead of typing on a laptop | The laptop animation comes from the Claude app. Install it, then choose **Rebuild Sprites**. |
| Tapping a buddy doesn't arrange the windows, or ⏯ doesn't control your music | Give it the Accessibility permission (see above). After an update, remove it from the list and add it again. |
| The installer says the build failed | Update the Command Line Tools under **System Settings > General > Software Update**, or run `xcode-select --install`, then install again. |
| The buddies never look busy | Watch what the app sees: `TBB_DEBUG=1 ./tbb run`, then `./tbb logs`. |
| The Control Strip is blank after quitting | Run `killall ControlStrip`. macOS restarts it right away. |

The log is at `~/Library/Logs/TouchBarBuddies.log` (`./tbb logs` follows it).

## Credits and disclaimer

Touch Bar Buddies is an unofficial fan project by Ben Pham. It isn't affiliated with, endorsed by, or
sponsored by Anthropic or OpenAI. Clawd belongs to Anthropic and the Codex pet belongs to OpenAI.
Claude, Claude Code, ChatGPT and Codex are their trademarks. This repository doesn't ship their artwork
(the GIFs above are recordings of the app). Your Mac makes its own copy from apps you already have and
from images claude.ai serves publicly, and that copy never leaves your Mac.

The app uses private macOS APIs to take over the Control Strip. A macOS update could break it, and it
could never be on the App Store. Use it for fun, at your own risk.

The code is MIT-licensed ([LICENSE](LICENSE)). The license covers the code only, not the characters.
