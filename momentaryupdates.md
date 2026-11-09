# Momentary updates (his words first)

**8.11.2026, Marko:** "I need to have tasks overview and agents overview of what's going on right now on all of my machines. You need to build a Star app: agent manager and viewer."

**9.11.2026, Marko:** "Please make my icon for Agent Manager CEO. Make it a black background, big three letters 'CEO', and add one prompt bar at the beginning and at the end, similar to my other icons like Claude or VM Remote. Same style, but maximize CEO as much as possible inside the icon."

**9.11.2026, Marko:** "This whole process we were doing with multiple agents and the cost agent checking, the whole last 24 hours: this kind of skill needs to be very well built. When I open my CEO and click at the top 'Open Mantra Operating System', this chat opens in iTerm. It has a name with '(Master)' in parentheses, and everything spawns from there. This is the master session, and we work with all agents from one central location. 'Open Mantra Operating System' from Agent Manager is exactly that: I open the session ready to continue, but it's not piling up — it summarizes everything into one skill, and the new chat opens with the skill." Status: v15, the button runs `mantra-master open` (skill master-session, ~/.mantra-os/master/STATE.md).

**9.11.2026, Marko:** "For these kinds of cases, in Agent Manager CEO, make one column next to the main interface: What stopped me? Then I can see these things, because now I don't know. I give you 25 different tasks and then things are not moving, and because they are not moving I need to know. And if it says I didn't enter something, I just click the button Solve, and it is presented again so I can do it." Status: v16, column WHAT STOPPED ME + command `mantra-block`.

**9.11.2026, Marko (on v17):** "In the CEO, add another column on the left side, and you can now remove the status line completely. It just shows any session now running, any agent running, with its model. If it's not running, it disappears from the list. And at the top I need the weekly credits and the session credits clearly seen." and "The right column, What stopped me, has no margin space on the left side. It looks ugly." Status: v18.

**9.11.2026, Marko (on v18):** "The What stopped me column should disappear when there is nothing there. And What stopped me doesn't give me any entry; I cannot answer anything in that column. I need to click Solve, and then you put the window forward and show me how I can do it, in the place of the problem, not remotely, please." Status: v18, records carry --where and --hint; SOLVE raises the real place.

**9.11.2026, Marko:** "Make WHAT STOPPED ME robust. If I solve the problem, detect it, solve it, and remove it from What stopped me." Status: v20, --check on every blocker, watcher every 30 s.
