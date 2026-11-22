# How it works

Blink Monitor is four small problems chained together. Only one of them is machine
learning, and it was made as small as possible on purpose.

```
camera frame ──> 1. find the eyes ──> 2. crop to 64x64 ──> 3. open or closed? ──> 4. blink?
 1920x1080        Apple Vision          Core Image           EyeNet (trained)      plain rules
```

The network is trained on the eyes of the person who uses it, and the app does that
itself the first time it runs: it records, trains and tests. The sections below follow
that order, then the counting.

A blink lasts 0.1 to 0.4 s, which is 3 to 12 frames at 30 frames a second. Asking one
network to find a blink in a whole 1920x1080 video would need far more data than one
person can record. Asking "is this small eye picture open or closed?" needs a few thousand
pictures.

## 1. Recording the data

The app's setup labels pictures **by instruction**: a voice says what to do, and every eye
picture taken during the next three seconds gets that label. Nobody clicks "open" or
"closed" on thousands of pictures.

<p align="center"><img src="img/poses.png" alt="The sixteen poses: eight with the eyes open, eight with the eyes closed" width="820"></p>

Three choices in the recording protocol (`Sources/BlinkCore/Recording/SessionScript.swift`):

- **Every pose is recorded open and closed.** A network learns whatever separates the two
  piles most easily. If "closed" always came with a lowered head, it would learn the head.
- **Some open poses look almost closed** (looking at the keyboard, a wide smile), so the
  only thing left that tells the piles apart is the eyelid.
- **One frame in three is kept.** Frames 33 ms apart are near copies.

Each session is one folder with a `manifest.csv` describing every picture (pose, eye,
head angle, crop size). Sessions matter for testing: see step 3.

**Before recording, the setup checks the camera**: a face in view for a second, each eye's
square at least as large as the 64 pixels the model reads, and enough light. The first is
required, since a recording of an empty chair teaches nothing. The other two are warnings.
The light limit is a starting value: every session this project was built on was brighter
than it, so nothing here shows where a model starts to fail.

**After recording, the session is checked**: pictures are only saved while a face is in
view, so a session that holds under 70% of what it can was partly recorded on an empty
chair. It is not kept, and the window says to record it again.

**Two sessions before the first training**, in different light. Measured on the author's
recordings (the table is in the README): trained on one session, the model found 55 to 70
of 72 real blinks depending on the session; on two, 60 to 72, and 69 on average.

## 2. Finding and cropping the eyes

`EyeLocator` asks Vision for the face's landmarks and computes one square per eye. The
square's side is 0.7 x the distance between the eyes: that distance stays stable when an
eye closes, while the eye's own outline collapses. `EyeCropper` resizes each square to
64x64.

When the head is turned far to one side, the far eye hides behind the nose and its
square lands on the cheek, so only the near eye is used.

Vision does this in two steps, find the face then place the landmarks on it, and the
first is half of the cost: it shrinks the whole 1920x1080 frame for its detector. A face
at a screen does not go far in half a second, so the face is looked for twice a second
only. In between, Vision is handed the box where the face was and places the landmarks
in it; the box follows the eyes it finds. Vision places landmarks wherever it is told to,
face or no face, so each result is checked: both eyes inside the box, and as far apart
as when the face was detected. If not, the whole frame is searched again at once.

This code lives in the shared library, `BlinkCore`. Recording and counting call the same
functions, and a test checks that the app's fast path produces the very pixels the
training pictures were made of.

## 3. The model

`training/model.py` defines EyeNet: four convolution stages (64 -> 32 -> 16 -> 8 -> 4
pixels), an average over the picture, and one output. It has 60,465 weights and the file
is 250 KB.

**The preprocessing is inside the model.** It drops colour and gives every picture the
same brightness and contrast, so a dim room and daylight look alike. Because it is part of
the model, the app cannot do it differently by mistake.

**Augmentation.** Each time a picture is shown during training it is altered in ways that
do not change the answer: mirrored, rotated up to 35 degrees, zoomed, shifted, blurred.

<p align="center"><img src="img/augmentation.png" alt="An open and a closed eye, each followed by seven altered copies" width="820"></p>

**Testing by session.** Pictures of one session are near copies of each other, so testing
on random pictures would flatter the model. Instead, for each session in turn, a model is
trained on all the others and tested on that one. `make train` prints that table, with the
errors broken down by pose, and saves the wrongly answered pictures to one sheet.

**Conversion.** `training/convert.py` translates the model to Core ML, then runs the same
real pictures through both versions and fails if any answer differs by more than 0.001.

### Training in the app

Everything above is the Python route (`make train`). It needs Python and PyTorch, 700 MB
of them, which nobody should have to install to count their blinks. So the app has the
same training written in Swift: `BlinkCore/Training`.

**The engine is MPSGraph**, Apple's framework for running and differentiating a network on
the Mac's graphics processor. PyTorch's own Mac mode is built on it, so this is the Python
route's engine without Python: the same network, the same alterations, the same optimiser
and schedule, 30 passes. Nothing is installed and nothing is added beside the app: with
the whole setup inside it, the app's program grew from 2.5 to 3.9 MB.

Three other ways were measured on the same pictures and splits before choosing
(commit `e2cb8a9` has their code; the README has the table):

| Way | Why not |
|---|---|
| Core ML's own on-device training | It can only train convolutions and fully-connected layers. Batch normalisation, dropout and the learning-rate schedule are lost: 211 of 216 blinks found, where MPSGraph and Python found all 216 |
| Create ML's image classifier | It counts well (71 of 72) but needs 2.8 ms to read one eye, against 0.1 ms. Too costly for an app that runs all day |
| MLX Swift | Its own instructions say the command line cannot build its graphics code without Xcode, which this project does not require |

**It runs in a helper process.** The app starts itself a second time with `--train`; that
copy only trains, and prints its progress line by line. The training happens inside
Apple's graphics frameworks, and when they fail they end the process they are in. In a
helper that is a training to start again. In the app it would be the app gone, in the
middle of its setup.

**The time left is measured, not guessed.** The window says nothing about time during the
first pass, which includes warming up. From the second pass on, it knows what a pass costs
on this Mac. On an M5 Pro the helper took 22 seconds for four sessions (3,721 pictures),
reading and checking included, and held about 650 MB while it ran. How long an older Mac
takes is not known.

**The model exists in two forms, and they are compared.** The trainer learns on the
graphics processor, with batch normalisation. What runs afterwards is the network written
out in Swift (`EyeNetwork`, four matrix products per eye on the processor), from weights
with the normalisation folded in. Core ML is not used for these models: it has no public
way to put new weights into a model. A mistake in that translation would not crash; the
model would simply answer worse. So after every training, every picture is given to both
forms, and a model whose two forms differ by more than 0.001 is not installed. This is
`convert.py`'s check, done on the user's Mac. A test also gives `EyeNetwork` the Python
model's weights and holds it to Python's answers on real pictures.

**A new model never overwrites the one in use.** The training writes to `model.new`. Only
a model that passed its check is moved into place, and the one it replaces is kept once,
so that a session that made things worse can be undone.

## 4. Real blinks

Eyes held open or closed are not blinks. In a real blink the lid is caught half-way and
blurred, and the first model missed them on the darker side of the face
([Lessons](LESSONS.md), number 2).

Started by `make monitor`, the app's Live View window has two record buttons. (The
downloaded app hides them, and the "cost per frame" table with them.) They record every frame for 30 or 60 seconds, with the
model's answer for each. From those captures:

- `training/label_captures.py` labels frames with the rule "both eyes blink together":
  when the model is sure about one eye, the other is labelled too, provided Vision's eye
  outline agrees. Half-way frames are left unlabelled.
- `training/annotate.py` lays out every possible blink for a person to mark as blink,
  partial or none. That is the ground truth.
- `training/evaluate.py` replays each capture through a model trained without it, and
  reports blinks found, missed and falsely counted.

**The setup's own test** is the short form of that measurement, for a user who has no
marked captures: ten ticks a second and a half apart, a blink at each, counted by the
model that was just trained through the very code that will count all day. A blink
answers the last tick played before it. Eight of ten is a pass, which leaves room for a
tick the person missed. Under eight, the app says the number and leaves the choice: one
more session where you sit now, the test again, or the model as it is.

The frames of real blinks that `label_captures.py` produces are only used by the Python
route so far. The app's own trainer learns from sessions alone.

## 5. Counting

The model only says "closed: 2%, 3%, 98%, 99%, 4%" thirty times a second.
`BlinkDetector` finds blinks in that stream with four rules:

| Rule | Why |
|---|---|
| Closed above 60%, open again only below 40% | An answer hovering near 50% would otherwise count a blink at every crossing |
| Two closed frames in a row, or one frame at least 80% sure | A lone hesitant frame is a model mistake; a lone sure frame is a fast blink |
| At most 0.6 s | Longer is resting or looking down, reported as a long closure |
| Nothing counted across a gap | If the face was lost while the eyes were closed, nobody knows when they reopened |

The two eyes' answers are averaged before the rules are applied. The rules exist in Swift
(the app) and in Python (the evaluation); a test reads the numbers out of the Swift file
and fails if the two copies differ.

## 6. History and reminders

The rate shown is blinks a minute **of time counted**: time away from the
screen does not lower it. One record per minute of the clock is appended to a CSV file.

A reminder needs evidence and restraint: a rate under your limit over the last three
minutes, with at least two of them watched, and never more than one reminder in five
minutes.

**The limit.** It starts at 10 blinks a minute. Once three hours have been watched over at
least two days, the app takes the median of those minutes as your usual rate and sets the
limit at 70% of it, never under the lowest limit you chose. The usual rate is then kept: nothing
recomputes it. If you blink less as the weeks go by, the gap to the usual rate is reported
("23% less than your usual rate") and the limit stays where it was. A baseline that followed
you would lower the bar as you declined, and hide the very thing it is for. Measuring again
is a button in Settings, with a warning when the new value is lower.

**What studies report.** `PublishedRates` (in `BlinkCore/History`) is the one place a
number from a study lives: three ranges of blink rates, each with its source, the
experiment, and the papers the Settings window lists. Healthy adults average 1.4 to 14.4 blinks a minute while
reading or at a screen, 8.0 to 21.0 looking straight ahead, and 10.5 to 32.5 in
conversation (Doughty 2001). The app shows these next to your own rate and limit, and
that is all they do:

- They are typical ranges, not ideal ones. No rate is established as enough, so the
  words never say "ideal", "healthy" or "normal", and a test checks the sentences.
- They never set the limit. That stays your own usual rate and your lowest limit.
- Nothing takes a colour because of them. Only your own limit turns a bar orange.

The same type holds the app's main source, an experiment (Chai 2025): 45 young adults
with dry eye symptoms fared worse after half an hour at 10 blinks a minute than at 20 or
at their own rate. Two things come from it. The floor starts at that 10. And the strip in
Settings marks the two rates as two dots, with nothing drawn between them, because nothing
between them was tested.

Healthy adults at a screen average about 5 complete blinks a minute (Freudenthaler 2003),
so a limit of 10 is above the usual rate of many people. Two things answer that. The floor
can be set from 1 to 20. And when the limit ends up above your own usual rate, Settings
says so, because the app would say "Low" most of the time.

[What is a healthy blink rate?](BLINK-RATE.md) is the research: the studies, their limits
and how each was read.

### One gate for every banner

The app has three kinds of reminder: the blink reminder, the look-away break and the
routines. Each one asks the same gate before it shows a banner (`BannerGate`, in
`Sources/BlinkCore/Monitoring`). The gate is a pure rule: it is handed the clock and the
facts, and its tests are moments written by hand.

| Rule | Why |
|---|---|
| Nothing during a look-away break, a blink break, a routine's timer or the setup | You are doing what the app asked. A break that falls due meanwhile waits, it is not lost |
| At least two minutes between two banners | Three gentle reminders in one minute are not gentle |
| A break goes first: the others stay away when one falls due within two minutes | The break has a clock running. The blink reminder comes back by itself |
| Quiet (30 minutes, an hour, until tomorrow) holds every banner and every sound | "Leave me alone" is one thing to say, not three. Counting goes on, and it is remembered |

The blink reminder also backs off (`ReminderPolicy`). While the rate stays low and
nothing answers, the next reminder comes after 5, 15, 30, then 60 minutes, and only the
first two make a sound. Three minutes above the limit start it over. A finished blink
break is an answer: its banner is taken back, and none comes for 20 minutes.

## 7. Breaks and pauses

Small pieces of logic, each a tested type in `BlinkCore/Monitoring`:

| Type | What it decides |
|---|---|
| `BlinkBreak` | The exercise counts every completed closure up to 3 s. Its blinks are slow on purpose and often last longer than the 0.6 s the counter accepts, so it has its own rule; the monitor's counting is not changed by it. While the exercise runs, nothing goes into the count: no watched time and no blink, or the exercise would be recorded as half a minute of barely blinking. |
| `BreakSchedule` | The look-away breaks: which one is due, short or long, and what counts as taken. See below. |
| `PauseState` | A pause knows when it ends, ends by itself, and survives a relaunch. |

### Look-away breaks

You choose four numbers (`BreakPlan`): the minutes between breaks, the seconds of a break,
how many short breaks come before a long one, and the minutes of the long one. The long
break can be switched off. The default is the classic rule: every 20 minutes, 20 seconds.

`BreakSchedule` has no clock and no window. It is told "at this time a face was in view" or
"was not", and answers with events. That is why it can be tested on timelines written by
hand.

| Rule | Why |
|---|---|
| Time at the screen runs while a face is in view. Losing the face for less than a short break changes nothing. | People look down, and the camera misses frames. |
| A due break starts by itself. A sound says when it is over. | A countdown on the screen would keep the eyes on the screen. |
| The sound at the end goes through macOS notifications, with a short "Break over" banner. The start sound and the end sound each have a switch. | The sound then follows the Mac's own notification sound and keeps quiet under a Focus. A muted Mac still sees that the break ended. |
| A short break lasts its seconds plus five. | Time to read the banner and turn away. |
| With no face in view for 60% of it, the break is recorded as **away**. Otherwise it is **on trust**. | The camera cannot tell where you look. The app does not claim what it did not see. |
| An absence as long as a break is a break, whenever it happens. | A break you take on your own counts. |
| In a long break only seconds with no face count. Back early, the count waits. After twice its length it is recorded as **cut short** and the cycle goes on. | A long break means leaving the screen. Asking again and again would teach you to switch it off. |
| A break can be put off for five minutes, once. It can be skipped, and that is counted. | Putting off should not become the habit. |
| Time when nothing was observed (a sleeping screen, a pause) is absence. | Nobody was at the screen, as far as the app knows. |

The day's breaks are counted by `BreakTally` and shown in the panel. The count to the next
long break does not stop at midnight; the tally does.

The app feeds the schedule the wall clock, not the camera's clock, so a night is a long
absence and not a jump. During a break a timer calls it once a second, because the camera
sends few updates while nobody is in view.

## 8. Routines

A routine is something you decided to do regularly for your eyes, such as putting in eye
drops at 08:00, 13:00 and 17:00. The app reminds you of it. It gives no advice: the times
are yours.

**What is due is worked out, never stored.** `RoutineDay` (in `BlinkCore/Routines`) takes
four things: the routine, the record, the clock and the calendar. It answers with today's
times and where each stands: to come, waiting, put off, done or left. Because nothing is
stored, nothing goes stale. The Mac can sleep through a time, or the app can start after
it, and the answer is simply worked out again.

| Rule | Why |
|---|---|
| A time waits until the routine's next time, or midnight for the last one. Then it is dropped | Two reminders never pile up: at 13:10 you get the 13:00 one, not the 08:00 one too |
| The record names a time by its day and its time on the wall clock (`2026-11-20T08:00`), with no time zone | Done at 08:00, then a flight west: 08:00 does not come a second time on the same date |
| A time that daylight saving skips falls due at the next minute that exists; a time that happens twice falls due once | The clock moving must neither lose a reminder nor double it |
| A time already past when the routine is switched on is not asked for | Switching it on at 13:10 must not answer with a reminder for 13:00 |

**The record** is `routines.csv`, beside the history: one line each time a reminder is
shown, done, put off or left. Lines are only added. Today's state in the panel, and how
well a routine was kept, both come from that file.

**Reminding gently** (`RoutinePolicy`, and `RoutineController` in the app):

- The app looks at the clock every 20 seconds. A reminder is shown only while somebody is
  at the screen: one that falls due while you are away is kept until you are back. While
  the camera is paused the app cannot see you, so an awake screen counts as somebody there.
- The banner makes no sound. It has two buttons, Done and Later (15 minutes).
  A routine with a timer has a third, Start Timer.
- If you touch nothing, it comes back once, ten minutes later. After that there are no
  more banners: a dot in the menu bar and a line in the panel wait until the time is done
  or its next time comes.
- One at a time, over all routines. Two banners are at least 5 minutes apart, and no more
  than 4 are shown in an hour. When several are due together, one that has had no banner
  goes before the repeat of another, and a time of day goes before a routine "at the
  screen". A reminder held back is not lost: the dot and the panel show it at once.
- Nothing is shown while a routine's timer runs, or during a blink break.
- "Quiet for Today" in the panel stops the banners until midnight. The dot and the panel
  still show what waits.
- The panel stays small. With one or two routines each is drawn in full. With more, only
  what waits is drawn in full, then one line says what comes next, and the rest is one
  click away.

What this cannot do: remind you while the app is not running. macOS could show a banner at
a fixed time by itself, but it would not know whether you are there, or that you already
pressed Done.

The schedule has three kinds: times of day, a number of times a week, and every so many
minutes at the screen.

### Every so many minutes at the screen

"Every 60 minutes at the screen" counts time with somebody there, not time on the clock.
`ScreenCount` (in `BlinkCore/Routines`) holds the rule. It has no clock and no camera of
its own: every 20 seconds the app tells it the time and whether somebody is there. So the
tests play whole days on timelines written by hand.

| Rule | Why |
|---|---|
| While somebody is there, the time since the last look is added | An hour of work, lunch, then twenty minutes of work is eighty minutes, not two hours and more |
| When the count reaches the minutes, the reminder is due and the count starts again at once | The next one is that many minutes of screen later, whatever you answer |
| A reminder left unanswered is replaced by the next one | Two never pile up |
| It gets one banner, with no repeat after ten minutes | It comes back by itself |
| Done starts the count again. Later (15 minutes) does not touch it | Done means "just now"; Later only moves the banner |
| Five minutes away in a row start the count again, and close a reminder left open | You got up. Nothing from before your break waits for you |
| A shorter absence only stops the count | Turning to the phone is not a break |
| A look that comes long after the last one is time away | The Mac slept, whatever the camera said last |
| While a routine's timer runs, the count stands still | Covered eyes are neither at the screen nor away |
| A new day starts at zero | Yesterday's last half hour is not owed today |

While the camera is paused, an awake screen counts as somebody there, as for the other
routines. What this cannot do: the count is kept in memory only. After a relaunch it
starts from zero, so that one reminder comes later. And anybody in front of the camera
counts as you.

### Routines of your own

The Routines tab of Settings adds a routine from a few starting points, each described by
what it does. Its name, symbol, kind of schedule and timer can be changed afterwards, and
it can be deleted. The two built-in routines can be switched off, not deleted.

| Rule | Why |
|---|---|
| A routine has an id drawn at random when it is made (`user-3f9a12c4`), apart from its name | Renaming loses no record: `routines.csv` names the routine by its id |
| The name is never written to `routines.csv` | Nothing typed can break the file |
| A typed name is kept to one line of 40 characters, with no control characters; an empty one is shown as "Reminder" | It appears in a banner, the panel and the menu bar |
| Deleting a routine leaves its lines in `routines.csv` | The file is only ever added to, and the id is never given again |
| Changing the kind starts the routine afresh from now | What waited under the old schedule has no meaning in the new one |
| At most 8 routines of your own | Reminders are only gentle while they are few |

### So many times a week

"Three times a week" is a count to reach, not three appointments. The routine has a
count, the days it prefers and one time of day. `RoutineWeek` (in `BlinkCore/Routines`)
decides whether a day asks, with one short rule:

- nothing asks once the count is reached;
- a preferred day asks, at the chosen time;
- another day asks when you are behind: the preferred days still to come are fewer than
  the times still to do.

"Behind" is judged from what was done before that day. So a day's answer does not change
during the day, and yesterday can be judged again today.

| What happens | What the app does | Why |
|---|---|---|
| You miss Wednesday | Thursday asks instead | The count can still be reached |
| You do it early, on a day that did not ask or before the time | It counts. "I Did It" is always in the panel | The count is what matters, not the day |
| You do it twice in one day | It counts as two | The count is yours. Undo takes back a press made by mistake, for the rest of that day |
| The count is out of reach late in the week | Each day left asks once, and no more | One reminder a day is the most this kind ever sends |
| A new week starts | The count starts at zero | Nothing is owed from last week |
| The routine is switched on in the middle of a week | That week asks on preferred days only | Catching up on a week you did not start would be nagging |
| The time zone changes | Nothing moves | A "done" is kept under the date on the wall clock (`2026-11-20`), like the times of day |
| The Mac sleeps for two days | One reminder on waking if you are behind, not three | What is due is worked out again from the record |

The week starts where the Mac's calendar says: Monday or Sunday. A day that asks has one
slot, which waits from its time until midnight. From there on it is an ordinary slot: the
record, Done and Later, the banner rules and the menu-bar dot treat it like a time of day.

The app keeps the last nine days of the record in memory. That covers the whole week, and
yesterday when yesterday belonged to the week before.

### A timer for a routine that takes a while

Under a mask you cannot see the screen, and the camera cannot see your eyes. A routine
can have a timer (`RoutineSession` for the rule, `RoutineSessionController` in the app).
The built-in heated eye mask has one. Its length is your setting: the app gives no advice
on how long or how warm, and its words send you to the instructions of what you use.

| The timer | Why |
|---|---|
| Holds the moment it ends, and compares it with the clock | A countdown stops while the Mac sleeps and is wrong afterwards |
| Pauses the camera until that moment, with the same pause as the Pause button | Covered eyes would be read as a low blink rate, or a long closure |
| Leaves a pause you chose yourself as it is | The timer must not switch the camera back on behind your back |
| Asks macOS not to sleep while it runs | Ten minutes without a key can put a Mac to sleep, and a sleeping Mac plays no sound |
| Holds the other routines' reminders until it is over | Nobody is looking at the screen |
| Plays a sound twice at the end, and marks the routine done | Your eyes are closed: the sound is what tells you |
| Stop ends it and marks nothing | "I Did It" is still there if it was done |
| Closing its window does not stop it | A stray click must not cost you the sound at the end |

What it cannot do: be heard with the Mac's sound off. And it is not kept across a
relaunch: quit the app and the timer is gone, though the camera's pause still ends by
itself at the same moment. If the Mac did sleep past the end (a closed lid), the routine is
marked done at the moment the timer ended, without a sound.

## 9. Keeping it cheap

The app runs all day, so its cost matters as much as its accuracy.

- Eye pictures reach the model as pixel buffers in its own format. The first version
  passed images and paid 9 ms per picture for it ([Lessons](LESSONS.md), number 3).
- A model trained in the app costs 0.24 ms per eye picture on its own, a Core ML one
  0.10 ms. In the app's log the model stage went from 0.8 to 1.9 ms a frame (one minute
  logged so far), small beside the 11 ms a frame takes, but worth tuning.
- The eyes are searched for every other frame; the frame in between reads the same squares.
  This saved 15% of a frame's cost, not the 40% expected: each search got slower. The README has the numbers.
- The face is looked for twice a second; the other searches only place the landmarks in
  its box (step 2). Whether this changed what is counted was measured before it shipped, on
  captures replayed from their whole frames. In the app's log a frame went from 14.7 ms to
  9.4 ms ([Lessons](LESSONS.md), number 5).
- After 3 s without a face, one frame in six is analysed. (Both rules are one tested type, `FrameSchedule`.)
- With no window open, the interface is updated on change and once a second.
- The camera picture is only prepared while the Live View window shows it.
- The pipeline times its own stages and logs them every minute.
