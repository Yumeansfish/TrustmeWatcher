# TrustmeWatcher

## Build from source

### macOS

#### 1. Prerequisites

Install Xcode Command Line Tools (Git, Make and Swift):

```bash
xcode-select --install
```

Install [Python 3.11](https://formulae.brew.sh/formula/python@3.11) and [Node.js 22](https://formulae.brew.sh/formula/node@22) (with npm) through [Homebrew](https://brew.sh/):

```bash
brew install python@3.11 node@22
export PATH="$(brew --prefix node@22)/bin:$PATH"
```

#### 2. Download and build

```bash
git clone --recurse-submodules https://github.com/Yumeansfish/TrustmeWatcher.git
cd TrustmeWatcher
make binary-app PYTHON_BIN=python3.11
```

This installs dependencies and builds `build/bin/app/trust-me.app`.

#### 3. Launch and permissions

From the repository directory, run:

```bash
open ./build/bin/app/trust-me.app
```

Open [TrustmeWatcher](http://127.0.0.1:5600/#/home) in your browser. You can double-click the app to launch it next time.

For permissions, see the Setup Manual.

### Windows

#### 1. Prerequisites

Install these tools and add them to `PATH`:

- Git for Windows, including Git Bash.
- Python 3.11 x64. Select **Add python.exe to PATH** during installation.
- Node.js 22 x64, including npm.
- GNU Make. With [Chocolatey](https://docs.chocolatey.org/en-us/choco/setup/), run `choco install make -y` in an administrator PowerShell window.

Reopen **Git Bash** and check:

```bash
git --version
python --version
node --version
make --version
```

Expected versions: Python `3.11.x`, Node `v22.x`.

#### 2. Download and build

In **Git Bash**, run:

```bash
git clone --recurse-submodules https://github.com/Yumeansfish/TrustmeWatcher.git
cd TrustmeWatcher
make binary-app
```

This installs dependencies and builds the app folder at `build\bin\app\trust-me\`.

#### 3. Launch and permissions

Log in to the Windows desktop. Open a normal **PowerShell** window in the repository directory and run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\start_windows_app.ps1 -AppDirectory .\build\bin\app\trust-me
```

## Runtime settings

Before testing remote features, complete section 6, SSH setup, in the Setup Manual.

Open **Settings → Remote Setup**:

- **SSH target**: Server login, such as `alice@10.20.30.40`, or a configured SSH alias.
- **Participant name**: Matches the participant's highlight videos and names their feedback files. See trust-me-setup for video naming.

## Features and testing

| Feature | Description | How to test | Expected result |
| --- | --- | --- | --- |
| Activity | Shows screen time based on ActivityWatch and records active apps. Browser and editor extensions provide more detailed activity. | Use two apps for a while, then check Activity. Check extension activity too, if installed. | Active apps and durations keep updating, including data from connected extensions. |
| Review | Fetches highlight videos when the backend starts and whenever the frontend opens. View Timeline below each video opens the matching activity period. | Select a date with videos, play one and click View Timeline. | The video plays and the timeline opens at its recording time. |
| Away Session | Records work done away from the computer and includes it in Activity. | Select Write Algo, click Start away session, then Resume tracking when you return. | Activity shows Write Algo and the session duration. |
| Home · Privacy Control | Starts and stops remote capture processes managed by trust-me-setup. | With SSH connected, switch capture off and on, then check the remote processes. | The displayed status matches the server. Capture restarts when switched on. |
| Home · Daily Check-ins | One morning and one afternoon check-in per day, divided at 12:00. The calendar shows one dot per check-in. After check-in, the app collects an hour of activity and generates suggestions. | Check in before 10:00 in the morning or before 15:00 in the afternoon. Keep the app and capture running for an hour. | Insights appear for the session, with a popup if there are actionable suggestions. |
| Home · TODO | Counts today's suggestions awaiting confirmation and questionnaires ready to fill in. | Click TODO when tasks are pending. | The page moves to the first pending card, which shakes briefly. |
| Home · Insights | Important is the default view, showing cards awaiting feedback, grouped by Morning and Afternoon. All shows every insight for the selected date. `!` marks a suggestion; `?` marks an open questionnaire. | Switch between Important, All and calendar dates, then open a card. | |
| Home · Insights empty state | Shows a panda and a greeting when there are no insights: Good morning before 12:00, Good afternoon from 12:00 to 17:00, and Good evening / Time to relax! from 17:00. | | |
| Suggestion confirmation and questionnaire reminders | A popup opens the Dashboard when suggestions are ready. Open each suggestion, read it and click Confirm to close the card. One hour after all suggestions in the session are confirmed, the questionnaires open and a reminder appears. | Confirm each suggestion, keep the app running for an hour after the last confirmation, then click the questionnaire popup. | The confirmation TODO count decreases. The feedback timer starts only after all confirmations. Once questionnaires open, `?` marks and questionnaire TODOs appear. |
| Questionnaire feedback | Open a card marked `?`. Answer whether you tried the suggestion; if Yes, answer whether it helped. | Submit the questionnaire and check the server's `name_feedback.csv`. | The question mark disappears, the TODO count decreases and the server stores the answers with `actual_shift`: the change in activity minutes for the suggested categories, comparing the hour after all confirmations with the hour used for the suggestion. |

Check-in closes at 10:00 for the morning and 15:00 for the afternoon. Confirm all suggestions by 11:00 or 16:00 respectively to receive a questionnaire one hour later.
Popups stay visible for five minutes unless clicked.

## Server results

After a participant submits a questionnaire, the app uploads one row per suggestion to `~/trust-me-setup/results/<participant_name>_feedback.csv` on the configured server.

Columns: `insight_window`, `metric`, `tried_to_follow`, `helped`, `submitted_at`, `suggestion`, `actual_shift`.

`suggestion` contains the recommended changes in minutes. `actual_shift` contains the observed changes for those categories: the hour after all confirmations minus the hour used for the suggestion. For example, Research increasing from 10 to 14 minutes is recorded as `Research +4 min`.
