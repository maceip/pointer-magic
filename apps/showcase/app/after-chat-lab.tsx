"use client";

import { useEffect, useMemo, useState } from "react";

type View = "report" | "halo" | "shadow" | "loom";

const navItems: { id: View; label: string; short: string }[] = [
  { id: "report", label: "Field report", short: "00" },
  { id: "halo", label: "Intent Halo", short: "01" },
  { id: "shadow", label: "Shadow Run", short: "02" },
  { id: "loom", label: "Apprentice Relay", short: "03" },
];

const evidence: { name: string; move: string; lesson: string; href: string; featured?: boolean }[] = [
  {
    name: "ChatGPT Atlas (retiring)",
    move: "Contextual assistant + opt-in agent mode",
    lesson: "Native context removed copy/paste, but Atlas is now winding down. Treat its interface as historical evidence.",
    href: "https://help.openai.com/en/articles/20001371-evolving-atlas-into-chatgpt-for-browser-based-agentic-work",
  },
  {
    name: "Comet",
    move: "Cross-tab sidebar + supervised control",
    lesson: "The assistant is always near, yet discoverability still depends on knowing what to ask.",
    href: "https://www.perplexity.ai/comet/resources/articles/comet-quick-start-guide",
  },
  {
    name: "Dia",
    move: "Reusable skills + exact-content previews",
    lesson: "Reusable skills make repeated tasks easier to name. Exact previews help people trust what will be inserted.",
    href: "https://www.diabrowser.com/security",
  },
  {
    name: "Magentic-UI",
    move: "Co-planning, guidance, interruption, approvals",
    lesson: "Control is a continuous collaboration surface, not a modal at the end.",
    href: "https://github.com/microsoft/magentic-ui",
  },
  {
    name: "Disco / GenTabs",
    move: "Tabs become bespoke interactive apps",
    lesson: "The most useful result may be a new interface, not a replay of automated clicks.",
    href: "https://blog.google/innovation-and-ai/models-and-research/google-labs/gentabs-gemini-3/",
  },
  {
    name: "Google AI Pointer / Magic Pointer",
    move: "Point at one or more things, then choose an action",
    lesson: "Pointing can replace part of a prompt. The cursor itself is no longer a new idea.",
    href: "https://deepmind.google/blog/ai-pointer/",
    featured: true,
  },
  {
    name: "Page Agent + VisBug",
    move: "In-page action + direct manipulation",
    lesson: "A browser tool can feel like part of the page when it stays next to the thing being changed.",
    href: "https://github.com/alibaba/page-agent",
  },
];

const laws = [
  ["Start from the selection", "If someone points to or selects something, begin there. Show relevant actions and leave room for a different request."],
  ["Show a result, not a status report", "When possible, produce a comparison, edit, or working tool instead of describing what the agent could produce."],
  ["Let people explore before changing anything", "Reading, comparing, and trying options should be safe. Ask before changing an account, file, purchase, or another person’s work."],
  ["Ask for approval when a change is ready", "Show what will happen and ask once before applying it. Do not interrupt for permission at every intermediate step."],
  ["Use waiting time for useful work", "If a task takes time, compare options, check sources, or do independent work in parallel. Do not animate clicks just to look busy."],
  ["Show sources and completed actions", "Show what information was used, what was selected, and what the agent did. Say clearly when a result is uncertain."],
  ["Be accurate about progress", "Show named stages only when they can be verified. Otherwise, say that the task is still running."],
  ["Make every change easy to undo", "Anything added to the page should be easy to close or reverse and should not interfere with the page’s own controls."],
];

function Mark() {
  return (
    <span className="mark" aria-hidden="true">
      <i />
      <i />
      <i />
    </span>
  );
}

function Arrow() {
  return <span aria-hidden="true">↗</span>;
}

export function AfterChatLab() {
  const [view, setView] = useState<View>("report");

  return (
    <main className={`lab-shell view-${view}`}>
      <header className="lab-header">
        <button className="brand" onClick={() => setView("report")} aria-label="Open field report">
          <Mark />
          <span>AFTER CHAT</span>
          <em>Browser agent UI lab</em>
        </button>
        <nav className="lab-nav" aria-label="Research and prototypes">
          {navItems.map((item) => (
            <button
              key={item.id}
              className={view === item.id ? "active" : ""}
              onClick={() => setView(item.id)}
              aria-current={view === item.id ? "page" : undefined}
            >
              <span>{item.short}</span>
              {item.label}
            </button>
          ))}
        </nav>
        <div className="header-note">
          <span className="live-dot" />
          INTERACTIVE STUDY · 2026
        </div>
      </header>

      {view === "report" && <Report onOpen={setView} />}
      {view === "halo" && <HaloDemo onNext={() => setView("shadow")} />}
      {view === "shadow" && <ShadowDemo onNext={() => setView("loom")} />}
      {view === "loom" && <RelayDemo onBack={() => setView("report")} />}
    </main>
  );
}

function Report({ onOpen }: { onOpen: (view: View) => void }) {
  return (
    <div className="report-page">
      <section className="report-hero">
        <div className="eyebrow"><span>FIELD NOTE 00</span><span>JUL 10, 2026</span></div>
        <h1>The browser agent should not look like <s>another chat box.</s></h1>
        <p className="hero-deck">
          The interface should show people what they can delegate, what the agent will change, and why
          handing it off is faster than doing it themselves.
        </p>
        <div className="hero-thesis">
          <div><span>OLD CENTER</span><strong>Prompt → watch clicks → hope</strong></div>
          <b aria-hidden="true">→</b>
          <div><span>NEW CENTER</span><strong>Choose a goal → review the result → approve the change</strong></div>
        </div>
        <div className="scroll-cue">SCROLL THE ARGUMENT <span>↓</span></div>
      </section>

      <section className="failure-strip" aria-label="Failure modes">
        <div><span>01</span><strong>People don’t know what to ask</strong><p>A blank prompt makes people figure out for themselves what the agent is useful for.</p></div>
        <div><span>02</span><strong>People can’t see what will change</strong><p>“Working…” conceals the line between reading and changing.</p></div>
        <div><span>03</span><strong>Watching the agent click</strong><p>Watching an agent replay serial clicks is slower and less clear than doing them.</p></div>
        <div><span>04</span><strong>Too many permission prompts</strong><p>Repeated prompts make a safe product feel unusable.</p></div>
      </section>

      <section className="report-section state-section">
        <div className="section-kicker">01 / THE STATE OF THE ART</div>
        <div className="section-heading">
          <h2>Useful features, but chat is still the main interface.</h2>
          <p>
            Today’s systems already have useful pieces: context, reusable skills, editable plans, approvals,
            source trails, session replay, and generated apps. But most still put the chat window at the center.
          </p>
        </div>
        <div className="evidence-grid">
          {evidence.map((item, index) => (
            <a href={item.href} target="_blank" rel="noreferrer" key={item.name} className={`evidence-card ${item.featured ? "evidence-card-featured" : ""}`}>
              <span className="evidence-index">0{index + 1}</span>
              <strong>{item.name}</strong>
              <em>{item.move}</em>
              <p>{item.lesson}</p>
              <Arrow />
            </a>
          ))}
        </div>
        <p className="inference-note">
          <strong>What this changes:</strong> Google has already shown the cursor as a way to start an AI task.
          Our version has to do more: show exactly what was selected, produce something useful on the page,
          and ask before it makes a lasting change.
        </p>
        <div className="baseline-shift">
          <div className="baseline-heading">
            <span>WHAT GOOGLE’S DEMO CHANGES · EXPERIMENTAL</span>
            <h3>Pointing can replace part of the prompt.</h3>
            <p>
              In Google’s demos, a person points at one or more things and says “this,” “that,” or “here.”
              The computer uses those selections to understand the request across apps. The glow is just decoration.
            </p>
          </div>
          <div className="baseline-grid">
            <div><strong>Choose several things</strong><p>Select items from the page without copying each one into chat.</p></div>
            <div><strong>Edit them in place</strong><p>Change a table, image, recipe, or document where it already lives.</p></div>
            <div><strong>Preview an action</strong><p>Turn a date, price, or place into a draft before anything happens.</p></div>
            <div><strong>Learn from a correction</strong><p>Use one correction to handle the next similar task better.</p></div>
          </div>
          <div className="baseline-footer">
            <p><b>What ours must add:</b> show exactly what is selected, what leaves the page, whether anything will change, and where the result will go.</p>
            <a href="https://deepmind.google/blog/ai-pointer/" target="_blank" rel="noreferrer">VIEW GOOGLE’S POINTER DEMOS <Arrow /></a>
          </div>
        </div>
      </section>

      <section className="report-section laws-section">
        <div className="section-kicker">02 / WHAT THE AGENT SHOULD DO</div>
        <div className="section-heading inverted">
          <h2>Eight things a browser agent needs to do well.</h2>
          <p>
            These rules describe what the interface should do: help people understand the available actions,
            see what the agent is using, correct mistakes, and approve changes before they happen.
          </p>
        </div>
        <div className="laws-list">
          {laws.map(([title, detail], index) => (
            <div key={title}>
              <span>{String(index + 1).padStart(2, "0")}</span>
              <strong>{title}</strong>
              <p>{detail}</p>
            </div>
          ))}
        </div>
        <div className="research-links">
          <a href="https://machinelearning.apple.com/research/mapping" target="_blank" rel="noreferrer">Apple / IUI 2026 UX design space <Arrow /></a>
          <a href="https://www.microsoft.com/en-us/haxtoolkit/ai-guidelines/" target="_blank" rel="noreferrer">Microsoft HAX guidelines <Arrow /></a>
          <a href="https://www.microsoft.com/en-us/research/articles/webwright-a-terminal-is-all-you-need-for-web-agents/" target="_blank" rel="noreferrer">Webwright reusable artifacts <Arrow /></a>
        </div>
      </section>

      <section className="report-section prototypes-section">
        <div className="section-kicker">03 / THREE PROTOTYPES</div>
        <div className="section-heading">
          <h2>Three interface ideas to test.</h2>
          <p>
            Each prototype addresses a different problem: choosing an action, reviewing a change, or teaching
            a repeated task. Testing them will show which approach works best.
          </p>
        </div>
        <div className="prototype-cards">
          <button onClick={() => onOpen("halo")} className="prototype-card halo-card">
            <span>01 · INVOKE</span>
            <div className="mini-halo"><i /><b>compare</b><i /></div>
            <h3>Intent Halo</h3>
            <p>Select something on the page and get a few useful actions. Type only when those suggestions miss.</p>
            <em>Solves: “I don’t know what to ask.”</em>
            <strong>OPEN PROTOTYPE <Arrow /></strong>
          </button>
          <button onClick={() => onOpen("shadow")} className="prototype-card shadow-card">
            <span>02 · DELEGATE</span>
            <div className="mini-shadow"><i /><i /><i /><b>COMMIT</b></div>
            <h3>Shadow Run</h3>
            <p>The agent rehearses in a copy, then shows you one clear change to review.</p>
            <em>Solves: “I don’t trust it to act.”</em>
            <strong>OPEN PROTOTYPE <Arrow /></strong>
          </button>
          <button onClick={() => onOpen("loom")} className="prototype-card loom-card">
            <span>03 · TEACH</span>
            <div className="mini-loom"><i /><i /><i /><i /></div>
            <h3>Apprentice Relay</h3>
            <p>Demonstrate one example; the browser turns it into a recipe and routes exceptions back to you.</p>
            <em>Solves: “It can’t know how I do this.”</em>
            <strong>OPEN PROTOTYPE <Arrow /></strong>
          </button>
        </div>
      </section>

      <section className="report-section decision-section">
        <div className="section-kicker">04 / WHAT TO BUILD FIRST</div>
        <h2>Start with selection and a clear preview of any changes.</h2>
        <div className="decision-table">
          <div className="table-head"><span>DIRECTION</span><span>BEST FIRST TASK</span><span>MAIN BENEFIT</span><span>MAIN RISK</span></div>
          <div><strong>Intent Halo</strong><span>Compare, explain, or extract selected items</span><span>Shows what is selected and asks before lasting changes</span><span>Too many suggestions, accidental selection, mouse-only access</span></div>
          <div><strong>Shadow Run</strong><span>Forms, settings, drafts, account changes</span><span>Shows the exact change before approval</span><span>The rehearsal may not match the live account</span></div>
          <div><strong>Apprentice Relay</strong><span>Repeated work with meaningful exceptions</span><span>Learns a repeatable task from one example</span><span>May learn the wrong rule</span></div>
        </div>
        <div className="recommendation">
          <span>SUGGESTED ORDER</span>
          <p>First, let people select one or more items and choose an action. Show comparisons and other read-only
          results right away. Preview edits on the page, and ask for approval before anything affects an account,
          sends information, or makes a purchase. For repeated tasks, let people save and edit the steps.</p>
        </div>
      </section>

      <footer className="report-footer">
        <Mark />
        <p>AFTER CHAT · A UI/UX RESEARCH PROTOTYPE<br />Uses mock data and simulated AI.</p>
        <button onClick={() => onOpen("halo")}>BEGIN WITH PROTOTYPE 01 <Arrow /></button>
      </footer>
    </div>
  );
}

function BrowserFrame({ children, title, tone = "light" }: { children: React.ReactNode; title: string; tone?: "light" | "dark" | "violet" }) {
  return (
    <div className={`browser-frame browser-${tone}`}>
      <div className="browser-tabs">
        <div className="window-dots"><i /><i /><i /></div>
        <div className="browser-tab active"><span className="tab-favicon" />{title}<b>×</b></div>
        <div className="new-tab">＋</div>
        <div className="browser-menu">⌄</div>
      </div>
      <div className="browser-bar">
        <span>‹</span><span>›</span><span>↻</span>
        <div className="address"><i /> secure.demo/{title.toLowerCase().replaceAll(" ", "-")}</div>
        <span>☆</span><span>⋮</span>
      </div>
      <div className="browser-viewport">{children}</div>
    </div>
  );
}

function PrototypeIntro({ number, title, thesis, onNext, nextLabel }: { number: string; title: string; thesis: string; onNext: () => void; nextLabel: string }) {
  return (
    <div className="prototype-intro">
      <div><span>PROTOTYPE {number}</span><h1>{title}</h1></div>
      <p>{thesis}</p>
      <button onClick={onNext}>{nextLabel} <Arrow /></button>
    </div>
  );
}

const haloFlights = [
  { id: "lumen", airline: "Lumen", time: "17:20", price: "$776", amount: 776, meta: "nonstop · 10h 40m", early: 92, quiet: 55, bagValue: 28 },
  { id: "morrow", airline: "Morrow", time: "18:40", price: "$884", amount: 884, meta: "nonstop · 2 bags included", early: 76, quiet: 72, bagValue: 100 },
  { id: "arc", airline: "Arc Air", time: "19:15", price: "$918", amount: 918, meta: "nonstop · quiet cabin", early: 58, quiet: 98, bagValue: 42 },
];

type HaloStage = "idle" | "selecting" | "compare" | "chosen" | "watch" | "watched";

function HaloDemo({ onNext }: { onNext: () => void }) {
  const [stage, setStage] = useState<HaloStage>("idle");
  const [selectedIds, setSelectedIds] = useState<string[]>([]);
  const [hoveredId, setHoveredId] = useState<string | null>(null);
  const [pointer, setPointer] = useState({ x: 0, y: 0, visible: false });
  const [compareScope, setCompareScope] = useState<"selected" | "page">("selected");
  const [watchTargetId, setWatchTargetId] = useState<string>("morrow");
  const [watchThreshold, setWatchThreshold] = useState(825);
  const [arrival, setArrival] = useState(72);
  const [quiet, setQuiet] = useState(64);
  const [bags, setBags] = useState(true);

  const selectedFlights = haloFlights.filter((flight) => selectedIds.includes(flight.id));
  const watchFlight = haloFlights.find((flight) => flight.id === watchTargetId) ?? haloFlights[1];

  const winner = useMemo(() => {
    const candidates = compareScope === "selected" && selectedIds.length > 1
      ? haloFlights.filter((flight) => selectedIds.includes(flight.id))
      : haloFlights;
    return [...candidates].sort((left, right) => {
      const leftScore = (left.early * arrival) + (left.quiet * quiet) + (bags ? left.bagValue * 74 : 0);
      const rightScore = (right.early * arrival) + (right.quiet * quiet) + (bags ? right.bagValue * 74 : 0);
      return rightScore - leftScore;
    })[0];
  }, [arrival, bags, compareScope, quiet, selectedIds]);

  const resetHalo = () => {
    setStage("idle");
    setSelectedIds([]);
    setHoveredId(null);
    setPointer((current) => ({ ...current, visible: false }));
    setCompareScope("selected");
    setArrival(72);
    setQuiet(64);
    setBags(true);
    setWatchThreshold(825);
  };

  const toggleFlight = (id: string) => {
    if (stage !== "idle" && stage !== "selecting") return;
    setSelectedIds((current) => {
      const next = current.includes(id) ? current.filter((item) => item !== id) : [...current, id];
      setStage(next.length === 0 ? "idle" : "selecting");
      return next;
    });
  };

  useEffect(() => {
    if (stage === "idle") return;
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      setStage(selectedIds.length ? "selecting" : "idle");
    };
    window.addEventListener("keydown", closeOnEscape);
    return () => window.removeEventListener("keydown", closeOnEscape);
  }, [selectedIds.length, stage]);

  return (
    <section className="prototype-page halo-page">
      <PrototypeIntro
        number="01"
        title="Intent Halo"
        thesis="Point at something on the page and the halo offers a few useful actions right there. Scope stays visible before anything runs."
        onNext={onNext}
        nextLabel="NEXT: SHADOW RUN"
      />
      <div className="prototype-stage">
        <div className="stage-instruction">
          <span>TRY IT</span>
          <p aria-live="polite">{
            stage === "idle" ? "Point at a flight and click to start. Tab + Enter works too."
              : stage === "selecting" ? "Add another flight, or choose an action from the scope tray."
                : stage === "compare" ? "Adjust the priorities; only the stated scope is compared."
                  : stage === "watch" ? "Review the threshold, notification, and expiry before creating the watch."
                    : stage === "watched" ? "The price watch is active, with an undo path."
                      : "The comparison lens is applied, with every reason still visible."
          }</p>
          <button onClick={resetHalo}>RESET</button>
          <a className="stage-source" href="https://deepmind.google/blog/ai-pointer/" target="_blank" rel="noreferrer">WHY THIS CHANGED <Arrow /></a>
        </div>
        <BrowserFrame title="Flight search">
          <div
            className={`travel-site ${stage === "idle" || stage === "selecting" ? "pointer-mode" : ""}`}
            onPointerMove={(event) => {
              const bounds = event.currentTarget.getBoundingClientRect();
              setPointer({ x: event.clientX - bounds.left, y: event.clientY - bounds.top, visible: true });
            }}
            onPointerLeave={() => setPointer((current) => ({ ...current, visible: false }))}
          >
            <header className="travel-header"><b>wayfare</b><nav>Explore <span>Trips</span> Stays</nav><div className="avatar">MC</div></header>
            <div className="search-summary"><span>SFO</span><b>→</b><span>CPH</span><i>Sep 12–20 · 1 traveler · Economy</i><button>Change</button></div>
            <div className="results-layout">
              <aside><strong>Filters</strong><label>Stops <span>Any</span></label><label>Departure <span>Morning</span></label><label>Bags <span>1+</span></label><div className="ad-block" /></aside>
              <section className="flight-results">
                <div className="result-meta"><strong>24 results</strong><span>Sorted by Recommended⌄</span></div>
                {haloFlights.map((flight) => (
                  <button
                    type="button"
                    className={`flight-card ${hoveredId === flight.id ? "focus-flight" : ""} ${selectedIds.includes(flight.id) ? "scope-selected" : ""} ${stage === "chosen" && flight.id === winner.id ? "selected-flight" : ""}`}
                    key={flight.id}
                    onPointerEnter={() => setHoveredId(flight.id)}
                    onPointerLeave={() => setHoveredId(null)}
                    onFocus={() => setHoveredId(flight.id)}
                    onBlur={() => setHoveredId(null)}
                    onClick={() => toggleFlight(flight.id)}
                    aria-pressed={selectedIds.includes(flight.id)}
                    aria-label={`${selectedIds.includes(flight.id) ? "Remove" : "Add"} ${flight.airline} ${flight.price} ${flight.meta} ${selectedIds.includes(flight.id) ? "from" : "to"} comparison scope`}
                  >
                    <div className="airline-logo">{flight.airline[0]}</div>
                    <div><strong>{flight.airline}</strong><span>{flight.meta}</span></div>
                    <div><strong>{flight.time}</strong><span>arrives +1</span></div>
                    <div><strong>{flight.price}</strong><span>round trip</span></div>
                  </button>
                ))}
              </section>
            </div>

            {(stage === "idle" || stage === "selecting") && pointer.visible && (
              <div className={`intent-pointer ${hoveredId ? "ready" : ""}`} style={{ left: pointer.x, top: pointer.y }} aria-hidden="true">
                <i>✦</i><span>↖</span>{hoveredId && <b>{selectedIds.includes(hoveredId) ? "REMOVE" : "ADD TO SCOPE"}</b>}
              </div>
            )}

            {stage === "selecting" && (
              <div className="scope-tray" role="dialog" aria-modal="false" aria-label="Intent Halo selection and actions">
                <div className="scope-tray-head">
                  <div><small>SELECTED ITEMS</small><strong>{selectedFlights.length} {selectedFlights.length === 1 ? "flight" : "flights"} selected</strong></div>
                  <button onClick={resetHalo} aria-label="Close Intent Halo">×</button>
                </div>
                <div className="scope-chips">
                  {selectedFlights.map((flight) => <button key={flight.id} onClick={() => toggleFlight(flight.id)}><i>{flight.airline[0]}</i><span>{flight.airline}<small>{flight.price}</small></span><b aria-hidden="true">×</b></button>)}
                  <span className="scope-add">Select another result to add it</span>
                </div>
                <div className="scope-actions">
                  <button onClick={() => { setCompareScope(selectedFlights.length > 1 ? "selected" : "page"); setStage("compare"); }}>
                    <span>{selectedFlights.length > 1 ? `Compare these ${selectedFlights.length}` : "Compare visible results"}</span><small>READ ONLY</small>
                  </button>
                  <button onClick={() => { setCompareScope(selectedFlights.length > 1 ? "selected" : "page"); setStage("compare"); }}>
                    <span>{selectedFlights.length > 1 ? "Show only the differences" : "Explain this trade-off"}</span><small>READ ONLY</small>
                  </button>
                  <button onClick={() => { const target = [...selectedFlights].sort((a, b) => a.amount - b.amount)[0] ?? haloFlights[0]; setWatchTargetId(target.id); setWatchThreshold(Math.max(700, target.amount - 50)); setStage("watch"); }}>
                    <span>Watch the lower fare</span><small>PERSISTENT · REVIEW</small>
                  </button>
                </div>
                <p>Nothing is sent on hover. Only the outlined flights are in scope.</p>
              </div>
            )}

            {(stage === "compare" || stage === "chosen") && (
              <div className="preference-sheet" role="dialog" aria-modal="false" aria-labelledby="comparison-title">
                <div className="sheet-top"><span>✦ READ-ONLY COMPARISON</span><button onClick={() => setStage("selecting")} aria-label="Close comparison">×</button></div>
                <div className="scope-summary"><span>SCOPE</span><div>{(compareScope === "selected" && selectedFlights.length > 1 ? selectedFlights : haloFlights).map((flight) => <i key={flight.id}>{flight.airline}</i>)}</div></div>
                <h3 id="comparison-title">What makes a flight good <em>for you?</em></h3>
                <p>Move the priorities. Results update in place—nothing is booked or saved.</p>
                <label><span><b>Arrive before dinner</b><i>{arrival}%</i></span><input type="range" min="0" max="100" value={arrival} onChange={(event) => { setArrival(Number(event.target.value)); setStage("compare"); }} /></label>
                <label><span><b>Quiet, low-stress cabin</b><i>{quiet}%</i></span><input type="range" min="0" max="100" value={quiet} onChange={(event) => { setQuiet(Number(event.target.value)); setStage("compare"); }} /></label>
                <button className={`toggle-row ${bags ? "on" : ""}`} onClick={() => { setBags(!bags); setStage("compare"); }}><span><b>Include the real bag price</b><i>Uses each airline’s current rules</i></span><em><i /></em></button>
                <div className="live-winner" aria-live="polite"><span>BEST FIT NOW</span><div><b>{winner.airline}</b><p>{winner.meta}</p><strong>{winner.price}</strong></div></div>
                <button className="apply-choice" onClick={() => setStage("chosen")}>{stage === "chosen" ? "✓ APPLIED TO RESULTS" : "APPLY THIS LENS"}</button>
                <small>REVERSIBLE LOCAL VIEW · clear anytime · current fare data</small>
              </div>
            )}

            {(stage === "watch" || stage === "watched") && (
              <div className="preference-sheet watch-sheet" role="dialog" aria-modal="false" aria-labelledby="watch-title">
                <div className="sheet-top"><span>✦ PERSISTENT ACTION · REVIEW</span><button onClick={() => setStage("selecting")} aria-label="Close price watch">×</button></div>
                <div className="watch-target"><i>{watchFlight.airline[0]}</i><div><span>WATCHING</span><b>{watchFlight.airline} · {watchFlight.price}</b></div></div>
                <h3 id="watch-title">Tell me when it drops below <em>${watchThreshold}</em>.</h3>
                <p>This leaves the page and keeps checking after you close it, so the terms are explicit.</p>
                <label><span><b>Price threshold</b><i>${watchThreshold}</i></span><input type="range" min="700" max="900" step="5" value={watchThreshold} onChange={(event) => { setWatchThreshold(Number(event.target.value)); setStage("watch"); }} /></label>
                <div className="effect-list">
                  <div><span>CHECKS</span><b>Twice a day</b></div>
                  <div><span>NOTIFIES</span><b>Browser notification only</b></div>
                  <div><span>EXPIRES</span><b>In 30 days</b></div>
                  <div><span>CAN DO</span><b>Alert you · never book</b></div>
                </div>
                <button className="apply-choice" onClick={() => setStage("watched")}>{stage === "watched" ? "✓ PRICE WATCH ACTIVE" : "CREATE PRICE WATCH"}</button>
                <small>Persistent rule · receipt and undo available</small>
              </div>
            )}
            {stage === "chosen" && <div className="page-toast"><span>✓</span><div><b>Lens applied</b><p>Results now reflect your priorities. Clear anytime.</p></div><button onClick={() => setStage("selecting")}>UNDO</button></div>}
            {stage === "watched" && <div className="page-toast"><span>✓</span><div><b>Price watch created</b><p>{watchFlight.airline} below ${watchThreshold} · expires in 30 days</p></div><button onClick={() => setStage("selecting")}>UNDO</button></div>}
          </div>
        </BrowserFrame>
      </div>
      <ConceptNotes
        thesis="The pointer supplies the object. The person chooses the action. The page then opens the right tool without hiding what is in scope."
        wins={["No prompt to invent", "Visible multi-object scope", "Read-only work stays fast", "Persistent actions get review"]}
        risk="The sparkle is not the product. If actions are generic, noisy, or pointer-only, this becomes a worse context menu."
      />
    </section>
  );
}

function ShadowDemo({ onNext }: { onNext: () => void }) {
  const [step, setStep] = useState(0);
  const [running, setRunning] = useState(false);
  const [committed, setCommitted] = useState(false);
  const [keepExport, setKeepExport] = useState(true);

  useEffect(() => {
    if (!running) return;
    const timer = window.setTimeout(() => {
      const nextStep = Math.min(step + 1, 4);
      setStep(nextStep);
      if (nextStep === 4) setRunning(false);
    }, 680);
    return () => window.clearTimeout(timer);
  }, [running, step]);

  const startRun = () => {
    setCommitted(false);
    setStep(1);
    setRunning(true);
  };

  return (
    <section className="prototype-page shadow-page">
      <PrototypeIntro
        number="02"
        title="Shadow Run"
        thesis="The agent rehearses in a copy of your account, then shows exactly what would change before you approve it."
        onNext={onNext}
        nextLabel="NEXT: APPRENTICE RELAY"
      />
      <div className="prototype-stage">
        <div className="stage-instruction shadow-instruction">
          <span>TRY IT</span>
          <p>{step === 0 ? "Run the rehearsal. It cannot touch the live account." : step < 4 ? "Watch the verified steps, not a fake cursor replay." : committed ? "The approved change is complete, with a receipt." : "Review the exact change, adjust what must stay untouched, then approve it once."}</p>
          <button onClick={() => { setStep(0); setRunning(false); setCommitted(false); }}>RESET</button>
        </div>
        <BrowserFrame title="Northstar account" tone="dark">
          <div className="billing-site">
            <header className="billing-header"><b>Northstar</b><nav>Overview Usage <span>Billing</span> Team</nav><button>Docs ↗</button><div className="avatar dark">AK</div></header>
            <div className="billing-body">
              <aside><strong>Billing</strong><span>Subscription</span><span>Payment methods</span><span>Invoices</span><span>Credits</span><i /><small>ACME STUDIO<br />Workspace #4281</small></aside>
              <section>
                <div className="billing-title"><div><small>SETTINGS / BILLING</small><h2>Subscription</h2></div><button>Manage plan</button></div>
                <div className="plan-card"><div><span>PRO PLAN</span><h3>$249 <small>/ month</small></h3><p>25 seats · renews Sep 18</p></div><b>Active</b></div>
                <h4>Workspace add-ons</h4>
                <div className="addon-row"><div className="addon-icon">EX</div><div><strong>Advanced exports</strong><span>Unlimited CSV and PDF exports</span></div><span>$49 / month</span><button>⋮</button></div>
                <div className="addon-row danger-row"><div className="addon-icon">AI</div><div><strong>AI Research Pack</strong><span>Added twice across two invoices</span></div><span>$89 / month</span><button>⋮</button></div>
              </section>
            </div>

            <div className="shadow-dock">
              <div className="shadow-command"><span className="shadow-glyph">◐</span><div><small>SHADOW RUN · LIVE ACCOUNT LOCKED</small><strong>Remove the duplicate AI add-on, but don’t change our export tools.</strong></div><button onClick={startRun} disabled={running}>{running ? "REHEARSING…" : step >= 4 ? "RUN AGAIN" : "REHEARSE"}</button></div>
              {step > 0 && (
                <div className="shadow-panel">
                  <div className="shadow-timeline">
                    {[
                      ["Read", "Current plan + 3 invoices"],
                      ["Detect", "Duplicate charge since Jun 18"],
                      ["Rehearse", "Cancellation in isolated twin"],
                      ["Verify", "Exports unchanged · access preserved"],
                    ].map(([label, detail], index) => (
                      <div className={`${step > index ? "done" : ""} ${step === index + 1 && running ? "active" : ""}`} key={label}>
                        <i>{step > index ? "✓" : index + 1}</i><span><b>{label}</b><small>{detail}</small></span>
                      </div>
                    ))}
                  </div>
                  {step < 4 && <div className="shadow-working"><span /><p>{step === 1 ? "Reading account state…" : step === 2 ? "Matching charges…" : "Verifying the reversible path…"}</p><button onClick={() => setRunning(false)}>STOP</button></div>}
                  {step >= 4 && (
                    <div className="shadow-contract">
                      <div className="contract-head"><div><span>READY FOR YOUR DECISION</span><h3>One change. $89/month saved.</h3></div><b>HIGH CONFIDENCE</b></div>
                      <div className="contract-diff">
                        <div><span>WILL CHANGE</span><p><i>−</i> AI Research Pack <b>$89 / month</b></p><small>Cancels before Sep 18 renewal · current access remains until then</small></div>
                        <div><span>WILL NOT CHANGE</span><p><i>✓</i> Pro plan · 25 seats</p><p><i>✓</i> Advanced exports · $49/month</p></div>
                      </div>
                      <button className={`contract-toggle ${keepExport ? "on" : ""}`} onClick={() => setKeepExport(!keepExport)}><span><b>Must stay untouched</b><small>Never alter Advanced exports</small></span><em><i /></em></button>
                      <div className="contract-actions"><button onClick={() => { setStep(0); setCommitted(false); }}>DISCARD</button><button onClick={() => setCommitted(true)} disabled={!keepExport || committed}>{committed ? "✓ COMMITTED" : "COMMIT 1 CHANGE"}</button></div>
                      <small className="contract-foot">Approval expires if account state changes · raw evidence available</small>
                    </div>
                  )}
                </div>
              )}
            </div>
            {committed && <div className="receipt-toast"><span>✓</span><div><b>Duplicate add-on cancelled</b><p>Receipt #NS-8842 · undo available for 10 minutes</p></div><button>VIEW RECEIPT</button></div>}
          </div>
        </BrowserFrame>
      </div>
      <ConceptNotes
        thesis="Instead of asking for permission at every step, the agent asks once for one clearly defined change."
        wins={["No repeated permission prompts", "No fake cursor replay", "Shows what will stay untouched", "Receipts + undo"]}
        risk="The copy must faithfully model the live account. When it cannot, the interface must say “proposed,” not “rehearsed.”"
      />
    </section>
  );
}

function RelayDemo({ onBack }: { onBack: () => void }) {
  const [phase, setPhase] = useState(0);
  const [highValue, setHighValue] = useState(true);
  const [foreign, setForeign] = useState(true);
  const [missing, setMissing] = useState(true);
  const [approved, setApproved] = useState(false);

  const reset = () => {
    setPhase(0);
    setHighValue(true);
    setForeign(true);
    setMissing(true);
    setApproved(false);
  };

  return (
    <section className="prototype-page loom-page relay-page">
      <PrototypeIntro
        number="03"
        title="Apprentice Relay"
        thesis="Do one real example. The browser turns your demonstration into an editable recipe, handles the ordinary cases, and routes exceptions back to you."
        onNext={onBack}
        nextLabel="BACK TO REPORT"
      />
      <div className="prototype-stage">
        <div className="stage-instruction loom-instruction">
          <span>TRY IT</span>
          <p>{phase === 0 ? "Teach with one receipt instead of writing a perfect prompt." : phase === 1 ? "Finish the example and check the rule it learned." : phase === 2 ? "Edit the stop rules before anything repeats." : phase === 3 ? "Preview which receipts are routine and which need you." : "Approve the eight routine drafts and keep the three exceptions for yourself."}</p>
          <button onClick={reset}>RESET</button>
        </div>
        <BrowserFrame title="Expense inbox" tone="violet">
          <div className="relay-app">
            <header className="relay-header"><div className="relay-logo">Ledgerly</div><nav><span>Inbox</span> Reports Vendors</nav><button>＋ New expense</button><div className="avatar relay-avatar">MO</div></header>
            <div className="relay-workspace">
              <aside className="receipt-list">
                <div className="receipt-list-head"><strong>Receipt inbox</strong><span>12 unread</span></div>
                {[
                  ["Adobe", "$58.99", "Creative Cloud · PDF attached", "today"],
                  ["Dropbox", "$24.00", "Team storage · attachment missing", "today"],
                  ["Harbor Hotel", "$812.40", "Offsite stay · PDF attached", "Tue"],
                  ["Uber", "€31.40", "Airport ride · JPG attached", "Tue"],
                ].map(([vendor, amount, detail, day], index) => (
                  <button key={vendor} className={index === 0 ? "active" : ""}><i>{vendor[0]}</i><div><b>{vendor}</b><span>{detail}</span></div><strong>{amount}</strong><small>{day}</small></button>
                ))}
              </aside>
              <section className="receipt-view">
                <div className="mail-meta"><div className="vendor-icon">A</div><div><strong>Your Adobe receipt</strong><span>Adobe · billing@adobe.com · 10:18 AM</span></div><button>•••</button></div>
                <div className="receipt-paper">
                  <b>Adobe</b><span>RECEIPT #ADB-92841</span><h3>$58.99</h3><p>Creative Cloud All Apps</p><div><span>July 10, 2026</span><strong>Visa •• 4821</strong></div>
                </div>
                <div className="attachment"><i>PDF</i><span><b>Adobe-Receipt-July.pdf</b><small>142 KB</small></span><button>Preview</button></div>
              </section>
              <aside className="expense-draft">
                <div className="draft-head"><span>EXPENSE DRAFT</span><b>Unsaved</b></div>
                <label>Vendor<input value="Adobe" readOnly /></label>
                <label>Date<input value="Jul 10, 2026" readOnly /></label>
                <label>Amount<input value="$58.99 USD" readOnly /></label>
                <label>Category<select defaultValue="software"><option value="software">Software</option></select></label>
                <label>Receipt<div className="file-pill">✓ Adobe-Receipt-July.pdf</div></label>
                <button className="save-draft">Save draft</button>
                <button className="submit-report" disabled>Submit report</button>
              </aside>
            </div>

            {phase === 0 && (
              <div className="teach-invitation">
                <span className="teach-spark">✦</span><div><small>APPEARS REPETITIVE</small><b>Teach this once?</b><p>I’ll watch this example and propose a reusable recipe. Nothing repeats yet.</p></div><button onClick={() => setPhase(1)}>TEACH WITH THIS RECEIPT</button><button className="dismiss-teach">×</button>
              </div>
            )}

            {phase === 1 && (
              <div className="teach-overlay">
                <div className="scope-band"><span>● TEACHING ONE EXAMPLE</span><b>Adobe receipt → Expense draft</b><button onClick={() => setPhase(0)}>STOP</button></div>
                <div className="action-trail"><span className="trail-one">1</span><span className="trail-two">2</span><span className="trail-three">3</span><i /><i /></div>
                <div className="teach-card"><small>WHAT I SAW</small><h3>A six-step recipe</h3><ol><li><i>1</i>Open an unread receipt</li><li><i>2</i>Read vendor, date, total</li><li><i>3</i>Create an expense draft</li><li><i>4</i>Attach the source file</li><li><i>5</i>Save as draft</li><li className="never"><i>×</i>Never submit</li></ol><button onClick={() => setPhase(2)}>FINISH EXAMPLE <span>→</span></button></div>
              </div>
            )}

            {phase === 2 && (
              <div className="recipe-modal">
                <div className="recipe-head"><span>✦ LEARNED RECIPE</span><button onClick={() => setPhase(1)}>EDIT DEMO</button></div>
                <h2>Receipt → expense draft</h2><p>Before this can repeat, decide what belongs back in your lane.</p>
                <div className="recipe-flow"><span>Unread receipt email</span><i>→</i><span>Draft expense row</span><i>→</i><span>Attach source</span><i>→</i><span>Save, never submit</span></div>
                <div className="stop-rules"><strong>STOP AND HAND BACK WHEN</strong>
                  <button className={highValue ? "on" : ""} onClick={() => setHighValue(!highValue)}><em><i /></em><span><b>Total is over $500</b><small>High-value review</small></span></button>
                  <button className={foreign ? "on" : ""} onClick={() => setForeign(!foreign)}><em><i /></em><span><b>Currency is not USD</b><small>Conversion needs judgment</small></span></button>
                  <button className={missing ? "on" : ""} onClick={() => setMissing(!missing)}><em><i /></em><span><b>Receipt file is missing</b><small>Cannot prove the expense</small></span></button>
                </div>
                <div className="recipe-actions"><button onClick={() => setPhase(0)}>DISCARD</button><button onClick={() => setPhase(3)}>PREVIEW ON 11 RECEIPTS</button></div>
              </div>
            )}

            {phase >= 3 && (
              <div className="relay-board">
                <header><div><span>RELAY PREVIEW · NO DRAFTS SAVED YET</span><h2>Eight are ordinary. Three need you.</h2></div><button onClick={() => setPhase(2)}>EDIT RECIPE</button></header>
                <div className="relay-lanes">
                  <section className="assistant-lane"><div className="lane-head"><span>ASSISTANT LANE</span><b>8 SAFE DRAFTS</b></div>
                    {["Adobe · $58.99", "Figma · $15.00", "Notion · $10.00", "Linear · $8.00", "Vercel · $20.00"].map((item, index) => <div key={item}><i>{phase === 4 ? "✓" : index + 1}</i><span><b>{item}</b><small>USD · receipt attached · software</small></span><em>{phase === 4 ? "READY" : "PREVIEW"}</em></div>)}
                    <button className="more-items">＋ 3 more ordinary receipts</button>
                  </section>
                  <section className="human-lane"><div className="lane-head"><span>YOUR LANE</span><b>3 EXCEPTIONS</b></div>
                    <div className="exception-card"><i>H</i><span><b>Harbor Hotel · $812.40</b><small>Stopped: total over $500</small></span><button>REVIEW</button></div>
                    <div className="exception-card"><i>U</i><span><b>Uber · €31.40</b><small>Stopped: foreign currency</small></span><button>REVIEW</button></div>
                    <div className="exception-card"><i>D</i><span><b>Dropbox · $24.00</b><small>Stopped: receipt missing</small></span><button>FIND FILE</button></div>
                  </section>
                </div>
                <div className="relay-summary"><span><i /> Every draft links back to its email + receipt</span><b>Never submits · never edits source mail</b><button onClick={() => { setPhase(4); setApproved(true); }} disabled={approved}>{approved ? "✓ 8 DRAFTS READY" : "PREPARE 8 SAFE DRAFTS"}</button></div>
              </div>
            )}
            {approved && <div className="relay-toast"><span>✓</span><div><b>The relay is working</b><p>8 drafts ready · 3 exceptions waiting for you · 0 reports submitted</p></div><button>OPEN DRAFTS</button></div>}
          </div>
        </BrowserFrame>
      </div>
      <ConceptNotes
        thesis="Teach one example, check the rules it learned, then let it handle routine cases while you deal with the exceptions."
        wins={["No perfect prompt to write", "Routine work continues while you review", "The learned rule stays visible", "Safety routes work instead of blocking it"]}
        risk="One example can teach the wrong habit. People need a preview, editable stop rules, and a link back to every source."
      />
    </section>
  );
}

function ConceptNotes({ thesis, wins, risk }: { thesis: string; wins: string[]; risk: string }) {
  return (
    <div className="concept-notes">
      <div><span>CORE IDEA</span><p>{thesis}</p></div>
      <div><span>WHY IT HELPS</span><ul>{wins.map((win) => <li key={win}>↳ {win}</li>)}</ul></div>
      <div><span>WHERE IT BREAKS</span><p>{risk}</p></div>
    </div>
  );
}
