# Magic Pointer: Five Working Experiments

Date: 2026-07-10  
Scope: what people see and do, how quickly the interface responds, what it remembers, and how it explains itself  
Out of scope: model choice, training, browser-control infrastructure, and production security

## Executive summary

The next version should start with the pointer.

People already point at the thing they are thinking about. That is much less work than opening a chat, describing the page, and explaining which object they mean. The pointer does not have to be right every time to be useful. It can begin as a fast, quiet feature that is occasionally very helpful. A wrong guess must be easy to ignore. A good guess must save more work than a button or keyboard shortcut.

Google has already shown one strong version of this idea. Its experimental AI Pointer and announced Googlebook Magic Pointer can collect objects and use them in another place. We should not copy that demo. We should test five other jobs a pointer could do:

1. **Threadline** finds relationships between something on the page and information in another open context.
2. **Pattern Brush** learns what a person means from a few marks and finds the rest.
3. **Timefold** lets a person inspect what an action would do now and later without taking the action.
4. **Source X-Ray** shows where an exact claim, number, or recommendation came from.
5. **Afterimage** notices a completed path and offers a shorter version when the next matching item appears.

These are five separate experiments, not five skins on the same action menu. Each uses a different pointer movement and produces a different kind of result.

The earlier report gave Intent Halo, Shadow Run, and Apprentice Relay equal weight. That is no longer the recommendation. Intent Halo did not do enough to beat existing page controls. Shadow Run and Apprentice Relay also ask people to trust and learn too much before receiving value. Their useful ideas remain as safeguards: show consequences before a lasting change, keep a link to the source, and make recovery easy. They are not separate products in this pass.

The implementation for this pass belongs in `showcase/` and runs locally.

## A correction to the first browser assessment

The original brief said ChatGPT Atlas, Perplexity Comet, and Dia had all failed. That was too broad. The first version of this report then went too far in the other direction and said all three were active and materially growing. That was also wrong as of July 10, 2026.

Verified product facts:

- OpenAI deprecated Atlas on July 9 and plans to shut it down on August 9.
- Comet is active and has at least one million Android downloads, but Perplexity does not publish current daily or monthly active-user numbers.
- Dia is shipping weekly releases, but there is no public user total or growth series that proves its audience is growing.

Sources: [Atlas deprecation notice](https://help.openai.com/en/articles/20001371-evolving-atlas-into-chatgpt-for-browser-based-agentic-work), [Comet Google Play listing](https://play.google.com/store/apps/details?id=ai.perplexity.comet&hl=en_US), [Dia release notes](https://www.diabrowser.com/release-notes/latest).

The narrower conclusion is the useful one:

> A browser with a chat panel does not, by itself, solve discovery, trust, speed, or useful handoff.

Product status and interface quality are different questions. A discontinued product can contain a useful interaction. An active product can still leave the central interface problem unsolved.

## How this report separates evidence from our ideas

The research sections below use two labels:

- **Verified reference:** what the linked product, paper, documentation, or local working prototype shows.
- **Our inference:** what we think it means for these five pointer experiments. It is a design judgment, not proof that people will want the feature.

## Reference points

### ChatGPT Atlas

**Verified reference:** Atlas kept the current page in view and made the move from ordinary help into browser control explicit. OpenAI is now retiring the product.

**Our inference:** if a pointer ever moves from reading into changing something, that change in power must be obvious. Atlas is useful historical interface evidence, not evidence of a growing browser.

Sources: [official deprecation notice](https://help.openai.com/en/articles/20001371-evolving-atlas-into-chatgpt-for-browser-based-agentic-work), [Atlas privacy controls](https://help.openai.com/en/articles/12574142-chatgpt-atlas-data-controls-and-privacy).

### Perplexity Comet

**Verified reference:** Comet separates help and research from browser actions. It includes Ask and Summarize entry points, editable shortcuts, domain permissions, and confirmation choices.

**Our inference:** reading and changing should never blur together. The pointer can inspect and compare quickly, but it should not quietly turn that inspection into control of the page or account.

Sources: [Comet getting started](https://www.perplexity.ai/help-center/en/articles/11172798-getting-started-with-comet), [permissions](https://www.perplexity.ai/help-center/en/articles/13531023-managing-comet-assistant-permissions), [shortcuts](https://www.perplexity.ai/help-center/en/articles/11897890-comet-shortcuts).

### Dia

**Verified reference:** Dia includes repeatable Skills, Morning Brief, Reports, Live Work, Live Docs, meeting preparation, persistent layouts, and suggestions based on the current context. Its security documentation says generated content is previewed before insertion, irreversible actions remain with the person, and a new chat does not automatically gain cross-tab or write access.

**Our inference:** the useful result should be something a person can inspect and keep using. A chat transcript is usually not the best result surface.

Sources: [current Dia product](https://www.diabrowser.com/), [Dia security model](https://www.diabrowser.com/security), [Skills gallery](https://www.diabrowser.com/skills).

### Google Disco and GenTabs

**Verified reference:** GenTabs turns open tabs and a stated goal into a custom interface. Generated elements remain linked to their original web sources.

**Our inference:** a browser can answer with a small working tool rather than a string of messages or automated clicks.

Sources: [Disco and GenTabs announcement](https://blog.google/innovation-and-ai/models-and-research/google-labs/gentabs-gemini-3/), [Disco](https://labs.google/disco/).

### Google AI Pointer and Googlebook Magic Pointer

**Verified reference:** Google DeepMind's experimental demos let a person point at meaningful objects and use short phrases such as “this,” “that,” and “here.” The examples include doubling recipe ingredients into a shopping list, editing an image by indicating source and destination, merging document content, and turning a restaurant shown in a paused video into a booking flow.

Googlebook's announced Magic Pointer mock-up collects two images, keeps small previews near the pointer, and offers actions including “Visualize Together,” “Compare Items,” and “Summarize.” Google describes Googlebook as a preview of devices planned for this fall. DeepMind describes its pointer work as experimental and says the public demo sequences were shortened. These are demonstrations of a direction, not proof of shipped speed, reliability, or adoption.

**Our inference:** the glow is not the important idea. Pointing can supply the missing noun in a request. Google has already shown object collection and transfer, so our work needs to explore other kinds of value. It should also show complete interactions rather than a shortened ideal path.

Sources: [Google DeepMind AI Pointer](https://deepmind.google/blog/ai-pointer/), [Googlebook announcement and Magic Pointer video](https://blog.google/products-and-platforms/platforms/android/meet-googlebook/).

### Magentic-UI and MagenticLite

**Verified reference:** Magentic-UI shows an editable plan, progress beside the controlled browser, steering, interruption, takeover, and checks before sensitive actions.

**Our inference:** approval is not enough on its own. A person also needs to understand what is happening, stop it, correct it, and recover. Those controls should appear only when the pointer leads to a longer or more consequential task.

Sources: [Magentic-UI repository](https://github.com/microsoft/magentic-ui), [human-centered design article](https://www.microsoft.com/en-us/research/blog/magentic-ui-an-experimental-human-centered-web-agent/), [MagenticLite](https://microsoft.github.io/magentic-ui/).

### `gui-agent`, PageAgent, and VisBug

**Verified reference:** [`aralroca/gui-agent`](https://github.com/aralroca/gui-agent) places status beside the affected page element. [PageAgent](https://alibaba.github.io/page-agent/docs/introduction/overview/) keeps its controls and feedback in the current page. [VisBug](https://github.com/GoogleChromeLabs/ProjectVisBug) supports direct pointing, inspection, multiple selection, and editing in the real page.

`gui-agent` is very new, so it is design evidence rather than proof of product use.

**Our inference:** target, movement, and result should stay close together. A person should not have to connect a remote activity log to a change somewhere else on the page.

### Notte, Stagehand, Playwright MCP, and Webwright

**Verified reference:**

- [Notte](https://github.com/nottelabs/notte) provides live view, recordings, replay, and escalation.
- [Stagehand](https://www.stagehand.dev/) separates observing possible actions from taking one.
- [Playwright MCP](https://github.com/microsoft/playwright-mcp) provides structured, repeatable inspection of page state.
- [Webwright](https://microsoft.github.io/Webwright/) turns repeated tasks into named programs.

**Our inference:** recordings, replay, and structured page evidence can support a trustworthy result. They should not become the main interface.

## What the local `dogsh` prototype proves about continuity

`dogsh` is a local working prototype in the sibling repository `../dogsh`. It is a terminal session that moves between a native Electron window and browser pages while preserving the same real shell, scrollback, cursor state, and live output.

**Verified in the local implementation:**

- The [README](../dogsh/README.md) describes one real terminal session with a native face and a browser face.
- Every face remains attached and rendered while hidden. A handoff reveals an already prepared destination instead of loading it at the moment of transition.
- A new face receives one full snapshot before it receives new live output. The ordering is enforced in [`app/main.js`](../dogsh/app/main.js).
- One choreographer records which surface currently owns the terminal. Only one face is shown at a time.
- Losing focus does not move the terminal by itself. Another surface has to make a clear focus claim.
- If the browser tab that owns the terminal closes, the terminal returns to the native window.
- The browser overlay in [`extension/src/content.js`](../dogsh/extension/src/content.js) uses a longer fly-in between native and browser surfaces, a short settle between tabs, and a fly-out when returning home.
- The [end-to-end run](../dogsh/e2e/run.js) checks a real shell command, a live full-screen terminal program, a tab-to-tab handoff, and a return to the native surface. The included screenshots and videos show that this is not only a static mock-up.

The prototype also documents important limits: screen-position mapping is approximate, the local WebSocket has no authentication, some browser pages cannot host an overlay, and the session ends with the app. Those are acceptable demo limits, not production decisions.

**Our inference for the pointer:**

1. Keep one real question or result, even when it has more than one visual form.
2. Prepare likely result states before revealing them. The pointer will feel slow if computation begins only after the visible transition starts.
3. Show only one active copy. Two competing lenses or result cards destroy the sense that the interface understands where the person is looking.
4. Do not move merely because the pointer left an object or a window lost focus. Move after a clear action or a strong repeated pattern.
5. Use motion when it explains where a result came from. Across similar browser pages, staying in the same place with a small settle may show continuity better than a large animation.
6. If the source disappears, close the temporary result or return it to a safe home. Never leave a confident-looking result attached to stale information.
7. Do not copy the terminal's large floating window, automatic focus following, full connection to every page, or automatic keyboard focus. The pointer should carry only the minimum information needed for the current result.

## The four problems a pointer can solve

### 1. People know what they are looking at before they know what to ask

A blank prompt makes the person name the task, describe the page, and identify the object. Pointing can remove that work.

### 2. Page controls know only the page that made them

A button can sort a table or open a dialog. It usually cannot connect a flight arrival to a calendar commitment, find the shared meaning across different wording, or explain the source behind a recommendation.

### 3. Small help is valuable when it is immediate

The pointer does not need to complete a long task to earn a place in the browser. It can save one comparison, one search, or one round of tab switching. That value disappears if the interface pauses, opens a panel, or asks for a prompt first.

### 4. A helpful pointer can quickly become an annoying or creepy pointer

It must stay quiet during ordinary movement. It must not send page contents merely because the pointer passed over them. Any short-term memory must be visible, local, easy to clear, and limited to the current session unless a person chooses otherwise.

## What the pointer has to get right

These are design targets for the prototypes, not findings already proved by research.

1. **Help without requiring a prompt.** The object, movement, or repeated path should supply enough context to start.
2. **React immediately.** The first visible response should come from local page state. Slower enrichment can fill in afterward without blocking the interaction.
3. **Stay quiet until there is a clear signal.** Ordinary hover is not permission to interrupt.
4. **Show what it is using.** The selected object, source, time point, or repeated path must remain visible.
5. **Produce the result directly.** Do not open the same “Explain, Compare, Summarize” menu in every demo.
6. **Keep the result near the reason it appeared.** The page should remain the main surface.
7. **Say what is known and what is estimated.** A source link does not make an inference certain.
8. **Never make a lasting change from pointer movement alone.** Inspection can be quick. Account changes, messages, purchases, and ongoing monitoring need a separate review.
9. **Provide equal keyboard and touch paths.** The idea can begin with the mouse without excluding people who use another input method.
10. **Make dismissal and reset obvious.** A bad suggestion should cost almost nothing.

## Experiment 1: Threadline

### What it does

Threadline connects two visible facts, then brings in the supporting facts needed to check whether they fit. It shows relationships; it does not move objects from one place to another.

### Working demo

The person connects two facts: flight AX 148 lands at CPH at 17:35 with a checked bag, and an in-person rehearsal at North House starts at 18:30. Threadline then uses Lea's request to arrive by 18:15, the 18:40 locked-door time, a 45-minute airport estimate, and a 32-minute trip across town.

The first result says the flight is too late: the person would leave the airport around 18:20 and reach North House around 18:52. That is 37 minutes after the requested arrival and 12 minutes after the door locks.

The result can be tested in place:

- **Carry-on only:** leave the airport around 18:00 and arrive around 18:32. That is two minutes after rehearsal begins and still leaves almost no buffer.
- **Earlier flight:** land at 15:55 and arrive around 17:12. That leaves 63 minutes before the requested arrival and costs $84 more.

For the late options, the person can also prepare and discard a late-arrival note. Nothing is booked, sent, or changed.

The showcase is a working simulation with fixed travel, email, map, and calendar data. It is not connected to a real calendar or travel account.

### Why it is better than a button or shortcut

No single page owns all of these facts. A shortcut cannot know which flight should be checked against which commitment. Connecting the pair gives Threadline a specific question, and the two supporting sources provide the calculation without copying either object.

### What could go wrong

- the wrong timezone, person, unit, or date is joined;
- private information from another tab appears without warning;
- weak connections create visual clutter;
- an estimate looks like a verified fact.

Threadline must show which contexts it used, mark estimates clearly, and return to the untouched workspace when the person closes or resets the result.

### The originality check

The two selected facts must produce a checked schedule, use supporting evidence, and let the person test a changed assumption. If the result is only a tray of selected cards or a generic “Compare” action, it has slipped back into Google's object-selection pattern.

## Experiment 2: Pattern Brush

### What it does

Pattern Brush learns a category from a few marks and finds other examples that use different words.

### Working demo

The support queue contains eight delivery cases. The person brushes across Maya's and Jo's cases as positive examples. Both have stalled tracking and repeated customer messages, although their wording is different.

The first rule finds five possible matches: Maya, Jo, Priya, Nina, and Omar. Priya already has a replacement in progress and Omar already has a refund in progress. The person switches to “Not this” and brushes Priya. That one correction updates the rule to leave out cases where a replacement or refund is already underway, removing both Priya and Omar. The final review contains Maya, Jo, and Nina.

The demo uses eight fixed support cases and known matches, so its behavior can be checked. It demonstrates the interaction, not a general claim that every support queue can be classified reliably.

### Why it is better than a button or shortcut

Text search finds the same words. Multiple selection gathers items the person already found. Pattern Brush has to find at least one relevant item the person did not touch and could not have found with the same literal search.

### What could go wrong

- the learned category is broader than the person intended;
- low-confidence matches look certain;
- related ideas are treated as the same idea;
- the rule is applied to a sensitive decision.

The inferred rule should be written in plain language. Confidence should be visible. A negative brush must change the result immediately.

### The originality check

The brush must find an unseen example with different wording and respond to a correction. If it only highlights the marks the person made, it is ordinary selection.

## Experiment 3: Timefold

### What it does

Timefold lets a person inspect the likely consequences of a control over time without using the control.

### Working demo

The team plan has 25 seats at $700 per month, with 18 active members, seven unused seats, and four planned hires. The person points at the seat setting, chooses a lower seat count, and moves through three points in time:

- **Today:** the unused seats that would be removed are shown, while all 18 current members keep access.
- **Next invoice:** the September 18 invoice changes by $28 for each removed seat.
- **In 90 days:** the chosen count is checked against 18 current members and four planned hires. The result shows either spare seats or the number of seats the team would be short.

The person can save the simulation as a draft change. The page states that no plan, access, or billing change has been made.

The showcase uses fixed billing and hiring data. It is a working interaction demo, not a forecast connected to a billing provider.

### Why it is better than a button or shortcut

The existing button shows the immediate action. Timefold exposes later cost, access, and policy effects that are normally spread across several screens.

### What could go wrong

- the interface gives false precision;
- a policy changes after the preview was prepared;
- an indirect consequence is missing;
- exploration feels too much like commitment.

Timefold should use a few clear checkpoints rather than a smooth invented future. Closing or resetting it must return to the current plan, and saving the simulation must create only a draft change.

### The originality check

Pointer position must change the future state being inspected and reveal at least one effect outside the visible control. If it is only a richer tooltip or an ordinary confirmation dialog, it is not enough.

## Experiment 4: Source X-Ray

### What it does

Source X-Ray pulls a visible number apart into its meaning, formula, source files, and individual records.

### Working demo

The revenue dashboard shows **$1.84M** in expected renewal revenue. Pointing at the number opens a trail that can be pulled through four layers:

1. **Meaning:** signed Q3 renewals after known churn and currency adjustments.
2. **Calculation:** $1.92M in signed contracts, minus $80K in known churn, plus a $0 currency adjustment.
3. **Sources:** 42 current CRM records, a churn CSV from June 28, and the current ECB exchange rate.
4. **Records:** the individual records behind the selected source.

The churn CSV is twelve days old and a July 10 file is available. Previewing the newer file changes known churn from $80K to $160K and lowers the displayed total from $1.84M to $1.76M. The person can draft a dashboard correction that keeps the old value in the audit history. The dashboard itself is not changed.

The demo uses fixed records, source dates, and formulas. It proves the layered source interaction, not that arbitrary dashboard numbers always have a recoverable trail.

### Why it is better than a button or shortcut

A normal source drawer can list files without explaining how they produced the visible total. Source X-Ray uses the selected number as the question, then keeps its meaning, calculation, sources, records, and previewed correction in one connected view.

### What could go wrong

- a source is present but does not support the claim;
- provenance is mistaken for truth;
- the system invents a history for opaque content;
- a source is old, unavailable, or copied from another weak source.

The lens must distinguish direct support, our inference, disagreement, and no trace. It should show freshness and the exact supporting fragment.

### The originality check

Pulling deeper must explain the number at four different levels, and replacing a stale source in preview must update the calculation. If it only opens an unchanged list of source links, the pointer is not adding enough.

## Experiment 5: Afterimage

### What it does

Afterimage notices a completed path, asks before keeping it, and offers a shorter version only when a matching item appears.

### Working demo

The person completes a normal four-step expense path for an Adobe receipt worth $58.99:

1. open the receipt;
2. choose the Software category;
3. attach `Adobe-Receipt.pdf`;
4. save the expense as a draft, never submit it.

The path stays visible while it is completed. Once finished, Afterimage says the same path also appeared twice earlier in the week and asks whether to add “Prepare expense draft” to the pointer for matching receipts. It does not keep the shortcut until the person agrees.

The person then opens a matching Dropbox receipt worth $24 with its PDF attached. A pointer action prepares the Dropbox draft in one step, adapting the vendor, amount, and source file while keeping the Software category and draft-only boundary. The result says that nothing was submitted and provides Undo.

The showcase uses fixed receipts and a fixed history for this demo. It demonstrates path compression and review; it does not prove that arbitrary work can be learned safely from one example.

### Why it is better than a button or shortcut

The feature waits until the person has successfully finished the work, then adapts the same meaningful steps to a matching receipt. There is no teaching mode, coordinate recording, or shortcut to configure before the first useful result.

### What could go wrong

- the completed path is not actually reusable;
- a new receipt contains an exception the shorter path misses;
- the offer appears before enough successful examples exist;
- the browser remembers steps longer than the person expected;
- the prepared draft is mistaken for a submitted expense.

Only a completed path should be eligible. The person must choose whether to keep it. The shorter run must preserve the source receipt, remain a draft, explain what it reused, and provide Undo.

### The originality check

The shorter path must reuse meaningful steps with new content rather than replay screen coordinates. If it requires a teaching session before the first success, or merely binds the old clicks to a hotkey, it is a macro rather than Afterimage.

## How the five experiments differ

| Experiment | What the person provides | What the pointer returns | The value a normal control misses |
|---|---|---|---|
| Threadline | Two facts that need to be checked together | A schedule calculation with supporting evidence and alternate assumptions | A join across pages or apps |
| Pattern Brush | A few positive and negative examples | An editable group of unseen matches | Meaning beyond literal search |
| Timefold | An action and a position in time | A reversible view of later effects | Consequences beyond the immediate dialog |
| Source X-Ray | Attention on a visible number | Its meaning, formula, sources, records, and a corrected preview | A direct map from a total to the data behind it |
| Afterimage | A completed path and permission to keep it | A one-step version adapted to the next matching item | Reuse without setup before the first success |

The five pointer forms should also look and move differently:

- Threadline uses lines between related facts.
- Pattern Brush leaves a temporary painted path and match field.
- Timefold stretches the affected state along a short timeline.
- Source X-Ray peels a number into progressively deeper layers.
- Afterimage turns a completed step trail into one saved pointer action.

If all five open the same floating card or list of actions, the work has failed even if the labels differ.

## What to build in this pass

Build all five as separate local experiments. Do not combine them into one product yet.

They may share a small amount of infrastructure:

1. local hit testing that knows which page element is under the pointer;
2. a fast first response from data already in the demo;
3. one visible result at a time;
4. a clear reset and a complete return to the original page state;
5. an equal keyboard path and a touch-friendly alternative;
6. labels that distinguish fixed demo data, retrieved facts, and estimates.

They should not share a generic action tray, a chat drawer, or a long “working” animation. Each experiment should produce its own result directly.

## What to test with people

### Basic value

- Did the result save more work than the page's existing control or a keyboard shortcut?
- Did the person understand why it appeared?
- Was it useful without instructions or a prompt?
- Would the person leave the feature on if it were right only occasionally?

### Speed

- How long passed between the meaningful pointer movement and the first visible response?
- Did the result feel attached to the pointer, or did it feel like a separate assistant arriving late?
- Could slower source checks fill in without blocking the first useful state?

### Mistakes and interruption

- How often did ordinary movement trigger the feature?
- Could a bad result be dismissed in one easy action?
- Did dismissal stop the same interruption from returning?
- Could the page always return fully to its original state?

### Understanding

- Could the person identify exactly which object, source, time point, or completed path caused the result?
- Could they tell a verified fact from an estimate or our inference?
- When information came from another context, was that context visible before private data appeared?

### Input and access

- Could a keyboard user reach the same result without imitating mouse movement?
- Could a touch user perform an equivalent deliberate action?
- Did any experiment depend on a movement pattern that excludes people with different motor behavior?

### Questions for each experiment

- **Threadline:** were the revealed relationships relevant, and were the calculations easy to check?
- **Pattern Brush:** did it find useful examples beyond literal search, and could the person correct the rule?
- **Timefold:** did the time view reveal a consequence the normal dialog hid without implying false certainty?
- **Source X-Ray:** did the layered calculation and records explain the number better than a source list?
- **Afterimage:** did the shorter expense path appear only after it had earned permission, and did the person understand that it prepared a draft rather than submitting one?

## Final position

The first useful version does not need to take over the browser. It needs to understand a small amount of what the person is pointing at and respond fast enough to feel like part of the pointer.

The best result may be modest: one hidden relationship, one group of similar support cases, one later consequence, one stale source, or one completed path made shorter for the next matching item. That is enough if it arrives immediately and costs almost nothing to ignore.

The pointer should not be a glowing shortcut to chat. It should become five different instruments for seeing something the page does not currently show.
