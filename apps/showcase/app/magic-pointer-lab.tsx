"use client";

import { useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { createPortal } from "react-dom";

type View = "report" | "threadline" | "brush" | "timefold" | "xray" | "afterimage";

const navItems: { id: View; label: string; short: string }[] = [
  { id: "report", label: "Field note", short: "00" },
  { id: "threadline", label: "Threadline", short: "01" },
  { id: "brush", label: "Pattern Brush", short: "02" },
  { id: "timefold", label: "Timefold", short: "03" },
  { id: "xray", label: "Source X-Ray", short: "04" },
  { id: "afterimage", label: "Afterimage", short: "05" },
];

const directions: { id: Exclude<View, "report">; number: string; name: string; dimension: string; premise: string; proof: string; className: string }[] = [
  {
    id: "threadline",
    number: "01",
    name: "Threadline",
    dimension: "RELATIONSHIPS",
    premise: "Point at facts in different places and ask how they fit together.",
    proof: "A shortcut can select several things. It cannot explain the relationship between them.",
    className: "thread-card",
  },
  {
    id: "brush",
    number: "02",
    name: "Pattern Brush",
    dimension: "PATTERNS",
    premise: "Brush across examples and let the page find the rest of the pattern.",
    proof: "The gesture teaches a rule instead of selecting rows one at a time.",
    className: "brush-card",
  },
  {
    id: "timefold",
    number: "03",
    name: "Timefold",
    dimension: "TIME",
    premise: "Point at a setting and drag forward to see what it changes later.",
    proof: "The pointer becomes a simulator, not another way to press the same button.",
    className: "time-card",
  },
  {
    id: "xray",
    number: "04",
    name: "Source X-Ray",
    dimension: "EVIDENCE",
    premise: "Point at a number and see every source that produced it.",
    proof: "The answer stays attached to the visible claim and can be checked in place.",
    className: "xray-card",
  },
  {
    id: "afterimage",
    number: "05",
    name: "Afterimage",
    dimension: "MEMORY",
    premise: "Finish a normal task once; the pointer notices the path and offers a shorter one next time.",
    proof: "No teaching session is required. The shortcut appears after useful work is already complete.",
    className: "after-card",
  },
];

const tests = [
  ["It must beat a shortcut", "Pointing has to provide meaning, relationships, history, or prediction that an ordinary hotkey does not have."],
  ["It must feel immediate", "The pointer response appears locally and instantly. Slower work can continue after the useful action is clear."],
  ["It must stay quiet", "Moving the mouse does not send data or open menus. The person deliberately starts every action."],
  ["A bad guess must be cheap", "The person can dismiss or correct a suggestion without losing their place."],
  ["Real changes need a preview", "Reading and simulation can happen immediately. Lasting or external changes wait for approval."],
];

function Mark() {
  return <span className="mark" aria-hidden="true"><i /><i /><i /></span>;
}

function Arrow() {
  return <span aria-hidden="true">↗</span>;
}

export function MagicPointerLab() {
  const [view, setView] = useState<View>("report");

  return (
    <main className={`lab-shell pointer-lab view-${view}`}>
      <header className="lab-header pointer-header">
        <button className="brand" onClick={() => setView("report")} aria-label="Open field note">
          <Mark />
          <span>MAGIC POINTER</span>
          <em>Five working experiments</em>
        </button>
        <nav className="lab-nav" aria-label="Field note and demos">
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
        <div className="header-note"><span className="live-dot" />LOCAL INTERACTIVE LAB</div>
      </header>

      {view === "report" && <Report onOpen={setView} />}
      {view === "threadline" && <ThreadlineDemo onNext={() => setView("brush")} />}
      {view === "brush" && <PatternBrushDemo onNext={() => setView("timefold")} />}
      {view === "timefold" && <TimefoldDemo onNext={() => setView("xray")} />}
      {view === "xray" && <SourceXRayDemo onNext={() => setView("afterimage")} />}
      {view === "afterimage" && <AfterimageDemo onNext={() => setView("report")} />}
    </main>
  );
}

function Report({ onOpen }: { onOpen: (view: View) => void }) {
  return (
    <div className="report-page pointer-report">
      <section className="report-hero pointer-hero">
        <div className="eyebrow"><span>FIELD NOTE 00</span><span>MAGIC POINTER · JUL 2026</span></div>
        <h1>The pointer should understand what you mean, not just <s>where you clicked.</s></h1>
        <p className="hero-deck">
          Google showed that pointing can replace part of a prompt. These five demos ask what the pointer can
          do next—without becoming a floating menu, a slower hotkey, or a copy of Google’s mock-up.
        </p>
        <div className="hero-thesis">
          <div><span>LOW UTILITY</span><strong>Point → menu → ordinary action</strong></div>
          <b aria-hidden="true">→</b>
          <div><span>HIGHER UTILITY</span><strong>Point → add meaning → reveal something new</strong></div>
        </div>
        <div className="scroll-cue">FIVE DIMENSIONS <span>↓</span></div>
      </section>

      <section className="failure-strip" aria-label="Requirements">
        <div><span>01</span><strong>Beat the hotkey</strong><p>If a shortcut already does the job, the pointer has not added enough.</p></div>
        <div><span>02</span><strong>Respond immediately</strong><p>The first useful response has to feel attached to the pointer.</p></div>
        <div><span>03</span><strong>Stay quiet</strong><p>Ordinary mouse movement should not trigger suggestions or send page data.</p></div>
        <div><span>04</span><strong>Be occasionally excellent</strong><p>It can miss sometimes if dismissal is free and the good moments save real work.</p></div>
      </section>

      <section className="report-section state-section">
        <div className="section-kicker">01 / THE STARTING POINT</div>
        <div className="section-heading">
          <h2>Google showed the opening. We still need to find the product.</h2>
          <p>
            Magic Pointer’s important move is not the glow. Pointing supplies “this,” “that,” and “here.”
            The computer can then work with the actual things the person means across a page or app.
          </p>
        </div>
        <div className="pointer-case-grid">
          <article><span>GOOGLE SHOWED</span><h3>Objects can become part of a request.</h3><p>Selecting two pictures gives the model the missing nouns without a long prompt.</p></article>
          <article><span>NOT ENOUGH</span><h3>A small action menu is still just a menu.</h3><p>If the result is “copy,” “open,” or “ask about this,” a button or shortcut may be faster.</p></article>
          <article><span>OUR TEST</span><h3>The pointer should reveal meaning that was not visible before.</h3><p>Relationships, patterns, future effects, source trails, and repeated behavior are five places to look.</p></article>
        </div>
        <p className="inference-note">
          <strong>Working belief:</strong> the intelligence can be imperfect at first. The interaction cannot feel slow,
          noisy, or pointless. A fast pointer that helps once or twice a day may earn more use than a powerful agent
          that asks people to learn a new workflow.
        </p>
        <a className="source-banner" href="https://deepmind.google/blog/ai-pointer/" target="_blank" rel="noreferrer">
          GOOGLE DEEPMIND’S EXPERIMENTAL POINTER DEMOS <Arrow />
        </a>
      </section>

      <section className="report-section prototypes-section pointer-directions">
        <div className="section-kicker">02 / FIVE DIMENSIONS</div>
        <div className="section-heading">
          <h2>Five things a pointer could understand.</h2>
          <p>Each demo changes a different part of the pointer: what it can connect, recognize, predict, explain, or remember.</p>
        </div>
        <div className="prototype-cards five-demo-cards">
          {directions.map((direction) => (
            <button key={direction.id} onClick={() => onOpen(direction.id)} className={`prototype-card ${direction.className}`}>
              <span>{direction.number} · {direction.dimension}</span>
              <div className={`pointer-mini mini-${direction.id}`} aria-hidden="true"><i /><i /><i /><b>✦</b></div>
              <h3>{direction.name}</h3>
              <p>{direction.premise}</p>
              <em>{direction.proof}</em>
              <strong>TRY THE DEMO <Arrow /></strong>
            </button>
          ))}
        </div>
      </section>

      <section className="report-section laws-section">
        <div className="section-kicker">03 / WHAT EACH DEMO MUST PROVE</div>
        <div className="section-heading inverted">
          <h2>The pointer earns its place or gets out of the way.</h2>
          <p>These are not visual concepts. Each one has to produce a useful result from direct interaction.</p>
        </div>
        <div className="laws-list pointer-tests">
          {tests.map(([title, detail], index) => (
            <div key={title}><span>{String(index + 1).padStart(2, "0")}</span><strong>{title}</strong><p>{detail}</p></div>
          ))}
        </div>
      </section>

      <section className="report-section decision-section pointer-decision">
        <div className="section-kicker">04 / PRODUCT ORDER</div>
        <h2>Start with the pointer. Let the heavier features appear only when needed.</h2>
        <div className="decision-table">
          <div className="table-head"><span>DEMO</span><span>THE POINTER ADDS</span><span>FIRST USE</span><span>FAILURE TEST</span></div>
          <div><strong>Threadline</strong><span>Relationships between separate facts</span><span>Check whether a plan fits</span><span>Connection is obvious without help</span></div>
          <div><strong>Pattern Brush</strong><span>A rule learned from spatial examples</span><span>Find matching rows</span><span>Manual filtering is faster</span></div>
          <div><strong>Timefold</strong><span>A view of future consequences</span><span>Preview a settings change</span><span>Simulation is vague or slow</span></div>
          <div><strong>Source X-Ray</strong><span>The source trail behind a visible claim</span><span>Check a dashboard number</span><span>Sources are already one click away</span></div>
          <div><strong>Afterimage</strong><span>A shorter path learned after normal work</span><span>Repeat a finished task</span><span>It interrupts before proving value</span></div>
        </div>
        <div className="recommendation">
          <span>SUGGESTED START</span>
          <p>Ship read-only versions first. Make activation instant and deliberate. Track whether people repeat an
          action after trying it once. Add previews and approval only when a pointer action begins to change something real.</p>
        </div>
      </section>

      <footer className="report-footer">
        <Mark />
        <p>MAGIC POINTER · FIVE WORKING EXPERIMENTS<br />Uses mock data and simulated AI.</p>
        <button onClick={() => onOpen("threadline")}>START WITH THREADLINE <Arrow /></button>
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
        <div className="address"><i /> local.demo/{title.toLowerCase().replaceAll(" ", "-")}</div>
        <span>☆</span><span>⋮</span>
      </div>
      <div className="browser-viewport">{children}</div>
    </div>
  );
}

function PrototypeIntro({ number, dimension, title, thesis, onNext, nextLabel }: { number: string; dimension: string; title: string; thesis: string; onNext: () => void; nextLabel: string }) {
  return (
    <div className="prototype-intro pointer-intro">
      <div><span>DEMO {number} · {dimension}</span><h1>{title}</h1></div>
      <p>{thesis}</p>
      <button onClick={onNext}>{nextLabel} <Arrow /></button>
    </div>
  );
}

const subscribeToClient = () => () => {};
const readClientSnapshot = () => true;
const readServerSnapshot = () => false;

function PointerSurface({ children, label, orbit, className = "" }: { children: React.ReactNode; label: string; orbit: [string, string, string]; className?: string }) {
  const pointerRef = useRef<HTMLDivElement>(null);
  const frameRef = useRef<number | null>(null);
  const nextPosition = useRef({ x: 0, y: 0 });
  const mounted = useSyncExternalStore(subscribeToClient, readClientSnapshot, readServerSnapshot);
  const orbitTone = className.split(" ")[0]?.replace("-workspace", "") || "thread";

  useEffect(() => {
    return () => {
      if (frameRef.current !== null) cancelAnimationFrame(frameRef.current);
    };
  }, []);

  const movePointer = (x: number, y: number) => {
    nextPosition.current = { x, y };
    if (frameRef.current !== null) return;
    frameRef.current = requestAnimationFrame(() => {
      if (pointerRef.current) {
        pointerRef.current.style.transform = `translate3d(${nextPosition.current.x}px, ${nextPosition.current.y}px, 0)`;
        pointerRef.current.style.opacity = "1";
      }
      frameRef.current = null;
    });
  };

  return (
    <div
      className={`pointer-surface ${className}`}
      onPointerMoveCapture={(event) => movePointer(event.clientX, event.clientY)}
      onPointerLeave={() => { if (pointerRef.current) pointerRef.current.style.opacity = "0"; }}
    >
      {children}
      {mounted && createPortal(
        <div ref={pointerRef} className={`lab-pointer orbit-${orbitTone}`} aria-hidden="true">
          <span className="pointer-orbit">
            {orbit.map((mark, index) => <i key={`${mark}-${index}`}><b>{mark}</b></i>)}
          </span>
          <strong className="pointer-core">✦</strong>
          <em className="pointer-label">{label}</em>
        </div>,
        document.body,
      )}
    </div>
  );
}

function DemoGuide({ text, onReset }: { text: string; onReset: () => void }) {
  return <div className="stage-instruction"><span>TRY IT</span><p aria-live="polite">{text}</p><button onClick={onReset}>RESET</button></div>;
}

function DemoNotes({ tests, why, failure }: { tests: string; why: string[]; failure: string }) {
  return (
    <div className="concept-notes">
      <div><span>WHAT IT TESTS</span><p>{tests}</p></div>
      <div><span>WHY USE THE POINTER</span><ul>{why.map((item) => <li key={item}>↳ {item}</li>)}</ul></div>
      <div><span>WHEN IT FAILS</span><p>{failure}</p></div>
    </div>
  );
}

const threadFacts = [
  { id: "flight", source: "TRAVEL", icon: "✈", title: "AX 148 lands at 17:35", detail: "CPH · checked bag", primary: true },
  { id: "rehearsal", source: "CALENDAR", icon: "▣", title: "Rehearsal starts at 18:30", detail: "North House · in person", primary: true },
  { id: "message", source: "LEA’S EMAIL", icon: "@", title: "Please arrive by 18:15", detail: "Doors lock at 18:40", primary: false },
  { id: "travel", source: "MAPS", icon: "⌁", title: "CPH to North House: about 32 min", detail: "Metro and walk · typical Wednesday", primary: false },
];

function ThreadlineDemo({ onNext }: { onNext: () => void }) {
  const [selected, setSelected] = useState<string[]>([]);
  const [checked, setChecked] = useState(false);
  const [drafted, setDrafted] = useState(false);
  const [resultMode, setResultMode] = useState<"conflict" | "carryon" | "alternative">("conflict");
  const [pointerLabel, setPointerLabel] = useState("SELECT A FACT");

  const reset = () => { setSelected([]); setChecked(false); setDrafted(false); setResultMode("conflict"); };
  const toggle = (id: string) => {
    setChecked(false);
    setDrafted(false);
    setResultMode("conflict");
    setSelected((current) => current.includes(id) ? current.filter((item) => item !== id) : [...current, id]);
  };
  const selectedFacts = threadFacts.filter((fact) => selected.includes(fact.id));
  const relationCopy = resultMode === "alternative"
    ? { flag: "EARLIER ARRIVAL", title: "The 15:55 arrival works.", arrival: "17:12", detail: "That leaves 63 minutes before the requested arrival time. It costs $84 more." }
    : resultMode === "carryon"
      ? { flag: "CARRY-ON ONLY", title: "Carry-on gets you there around 18:32.", arrival: "18:32", detail: "That is 2 minutes after rehearsal starts and 17 minutes after the requested arrival. You may beat the locked door, but there is almost no buffer." }
      : { flag: "TIMING CONFLICT", title: "This flight is too late.", arrival: "18:52", detail: "Checked-bag pickup and the trip across town put you 37 minutes past the requested arrival and 12 minutes past the locked door." };

  return (
    <section className="prototype-page pointer-demo-page threadline-page">
      <PrototypeIntro number="01" dimension="RELATIONSHIPS" title="Threadline" thesis="Point at facts in different places. The pointer checks how they fit together and shows the result without moving or copying them." onNext={onNext} nextLabel="NEXT: PATTERN BRUSH" />
      <div className="prototype-stage">
        <DemoGuide text={checked ? "The relationship is live. Try a different assumption without booking or changing anything." : selected.length < 2 ? "Connect the arriving flight to the rehearsal." : "The question is ready. Check whether the plan fits."} onReset={reset} />
        <BrowserFrame title="Wednesday workspace">
          <PointerSurface className="thread-workspace" label={pointerLabel} orbit={["1", "2", "="]}>
            <header className="workspace-top"><b>Wednesday, Sep 17</b><span>One live question · four ready sources</span><em>POINTER MODE ON</em></header>
            <div className="context-grid">
              {threadFacts.map((fact) => (
                <button
                  key={fact.id}
                  className={`context-fact fact-${fact.id} ${selected.includes(fact.id) ? "selected" : ""} ${checked && !fact.primary ? "support-used" : ""}`}
                  onClick={() => fact.primary && toggle(fact.id)}
                  onPointerEnter={() => setPointerLabel(fact.primary ? (selected.includes(fact.id) ? "REMOVE FACT" : "CONNECT THIS") : "READY AS EVIDENCE")}
                  onFocus={() => setPointerLabel(fact.primary ? (selected.includes(fact.id) ? "REMOVE FACT" : "CONNECT THIS") : "READY AS EVIDENCE")}
                  aria-pressed={selected.includes(fact.id)}
                  aria-disabled={!fact.primary}
                >
                  <span>{fact.source}</span><i>{fact.icon}</i><strong>{fact.title}</strong><p>{fact.detail}</p><b>{selected.includes(fact.id) ? "✓ CONNECTED" : checked && !fact.primary ? "ALSO USED" : fact.primary ? "CONNECT" : "READY"}</b>
                </button>
              ))}
            </div>
            {selected.length > 0 && !checked && (
              <div className="thread-dock">
                <div><small>SELECTED FACTS</small><span>{selectedFacts.map((fact) => <i key={fact.id}>{fact.source}: {fact.title}</i>)}</span></div>
                <button disabled={selected.length < 2} onClick={() => setChecked(true)}>CHECK THE CONNECTION</button>
              </div>
            )}
            {checked && (
              <div className="thread-result" role="dialog" aria-modal="false" aria-label="Relationship result">
                <div className="result-flag">{relationCopy.flag}</div>
                <h2>{relationCopy.title}</h2>
                <div className="thread-timeline">
                  <span><b>{resultMode === "alternative" ? "15:55" : "17:35"}</b><small>Land</small></span><i /><span><b>{resultMode === "alternative" ? "16:40" : resultMode === "carryon" ? "18:00" : "18:20"}</b><small>Leave airport</small></span><i /><span className={resultMode === "alternative" ? "" : "late"}><b>{relationCopy.arrival}</b><small>Reach North House</small></span><i /><span><b>18:15</b><small>Asked arrival</small></span>
                </div>
                <p>{relationCopy.detail}</p>
                <div className="also-used"><span>ALSO USED</span><i>Lea’s email</i><i>{resultMode === "carryon" ? "25 min airport estimate" : "45 min airport estimate"}</i><i>32 min travel estimate</i></div>
                <div className="relation-actions">
                  {resultMode !== "carryon" && <button onClick={() => { setResultMode("carryon"); setDrafted(false); }}>TRY CARRY-ON ONLY</button>}
                  {resultMode !== "alternative" && <button onClick={() => { setResultMode("alternative"); setDrafted(false); }}>SHOW AN EARLIER ARRIVAL</button>}
                  {resultMode !== "conflict" && <button onClick={() => { setResultMode("conflict"); setDrafted(false); }}>BACK TO ORIGINAL</button>}
                </div>
                {resultMode !== "alternative" && (!drafted ? <button onClick={() => setDrafted(true)}>DRAFT A LATE-ARRIVAL NOTE</button> : <div className="draft-note"><span>DRAFT</span><p>My flight lands at 17:35. I’m likely to reach North House after rehearsal begins. May I join remotely until I arrive?</p><button onClick={() => setDrafted(false)}>DISCARD</button></div>)}
                <button className="close-result" onClick={() => setChecked(false)} aria-label="Close result">×</button>
              </div>
            )}
          </PointerSurface>
        </BrowserFrame>
      </div>
      <DemoNotes tests="Can pointing reveal a useful relationship between facts that live in separate places?" why={["The question survives across four sources", "Estimates are separated from known facts", "The answer can test a new assumption in place"]} failure="If the relationship is already obvious, a normal multi-select is faster." />
    </section>
  );
}

const brushRows = [
  { id: "maya", ticket: "S-1842", customer: "Maya Chen", message: "Still waiting. This was for a birthday Friday.", tracking: "Label created · 4 days", replies: 2, state: "Open" },
  { id: "jo", ticket: "S-1849", customer: "Jo Park", message: "Any update? It has not moved all week.", tracking: "No scan · 5 days", replies: 3, state: "Open" },
  { id: "priya", ticket: "S-1853", customer: "Priya Shah", message: "Order has not moved since Monday.", tracking: "No scan · 4 days", replies: 2, state: "Replacement sent" },
  { id: "nina", ticket: "S-1857", customer: "Nina Brooks", message: "It was due yesterday. I travel Friday.", tracking: "Label created · 3 days", replies: 2, state: "Open" },
  { id: "tom", ticket: "S-1861", customer: "Tom Reyes", message: "Marked delivered, but it is not here.", tracking: "Delivered today", replies: 2, state: "Open" },
  { id: "alex", ticket: "S-1864", customer: "Alex Stein", message: "Can I change the delivery address?", tracking: "Scan 3 hours ago", replies: 1, state: "Open" },
  { id: "omar", ticket: "S-1870", customer: "Omar Ali", message: "Late again. Please cancel it.", tracking: "No scan · 6 days", replies: 2, state: "Refund pending" },
  { id: "elise", ticket: "S-1873", customer: "Elise Wong", message: "Tracking is slow, but there is no rush.", tracking: "No scan · 4 days", replies: 1, state: "Open" },
];

function PatternBrushDemo({ onNext }: { onNext: () => void }) {
  const [samples, setSamples] = useState<string[]>([]);
  const [exceptions, setExceptions] = useState<string[]>([]);
  const [mode, setMode] = useState<"include" | "exclude">("include");
  const [brushing, setBrushing] = useState(false);
  const [applied, setApplied] = useState(false);
  const [pointerLabel, setPointerLabel] = useState("BRUSH AN EXAMPLE");
  const broadMatches = ["maya", "jo", "priya", "nina", "omar"];
  const refinedMatches = ["maya", "jo", "nina"];
  const ruleReady = samples.length >= 2;
  const refined = exceptions.length > 0;
  const matches = (refined ? refinedMatches : broadMatches).filter((id) => !exceptions.includes(id));

  useEffect(() => {
    const stop = () => setBrushing(false);
    window.addEventListener("pointerup", stop);
    return () => window.removeEventListener("pointerup", stop);
  }, []);

  const paint = (id: string) => {
    setApplied(false);
    if (mode === "exclude" && ruleReady) {
      setExceptions((current) => current.includes(id) ? current : [...current, id]);
      return;
    }
    setSamples((current) => current.includes(id) ? current : [...current, id]);
  };
  const reset = () => { setSamples([]); setExceptions([]); setMode("include"); setApplied(false); setBrushing(false); };

  return (
    <section className="prototype-page pointer-demo-page brush-page">
      <PrototypeIntro number="02" dimension="PATTERNS" title="Pattern Brush" thesis="Brush across a few examples. The pointer turns what they have in common into a rule and finds the other matches." onNext={onNext} nextLabel="NEXT: TIMEFOLD" />
      <div className="prototype-stage">
        <DemoGuide text={applied ? "The learned rule is showing three cases. Return to all cases or reset." : refined ? "One correction removed two resolved cases. Open the three-case review." : ruleReady ? "Five cases match. Switch to Not this and paint Priya to correct the rule." : "Press and drag across Maya and Jo to show what belongs together."} onReset={reset} />
        <BrowserFrame title="Support queue">
          <PointerSurface className="brush-workspace" label={pointerLabel} orbit={["+", "≈", "−"]}>
            <header className="data-header"><div><span>SUPPORT / DELIVERY</span><h2>{applied ? "Cases to review" : "Open cases"}</h2></div><b>{applied ? `${matches.length} matches` : "8 cases"}</b></header>
            <div className="brush-help"><span>BRUSH MODE</span><p>Paint examples. The pointer keeps one rule and updates it instead of starting over.</p></div>
            <div className="brush-tools" aria-label="Brush type">
              <button className={mode === "include" ? "active include" : "include"} onClick={() => setMode("include")}><i /> THIS BELONGS</button>
              <button className={mode === "exclude" ? "active exclude" : "exclude"} onClick={() => ruleReady && setMode("exclude")} disabled={!ruleReady}><i /> NOT THIS</button>
              <span>{brushing ? "PAINTING…" : mode === "include" ? "Add positive examples" : "Mark an exception"}</span>
            </div>
            <div className={`data-table ${applied ? "queue-view" : ""}`} role="group" aria-label="Support cases">
              <div className="data-row data-head" aria-hidden="true"><span>CASE</span><span>CUSTOMER</span><span>MESSAGE</span><span>TRACKING</span><span>REPLIES</span><span>STATE</span></div>
              {brushRows.map((row) => {
                const sample = samples.includes(row.id);
                const inferred = ruleReady && matches.includes(row.id) && !sample;
                const hidden = applied && !matches.includes(row.id);
                const exception = exceptions.includes(row.id) || (refined && ["priya", "omar"].includes(row.id));
                return (
                  <button
                    key={row.id}
                    className={`data-row ${sample ? "sample" : ""} ${inferred ? "inferred" : ""} ${exception ? "exception" : ""} ${hidden ? "filtered-out" : ""}`}
                    onPointerDown={() => { setBrushing(true); paint(row.id); }}
                    onPointerEnter={() => { setPointerLabel(mode === "exclude" ? "MARK NOT THIS" : sample ? "EXAMPLE ADDED" : "BRUSH THIS CASE"); if (brushing) paint(row.id); }}
                    onClick={(event) => { if (event.detail === 0) paint(row.id); }}
                    aria-pressed={sample || exception}
                  >
                    <span><b>{row.ticket}</b>{sample && <em>EXAMPLE</em>}{inferred && <em>MATCH</em>}{exception && <em>NOT THIS</em>}</span>
                    <span>{row.customer}</span><span>{row.message}</span><span>{row.tracking}</span><span>{row.replies}</span><span className={row.state === "Open" ? "" : "resolved"}>{row.state}</span>
                  </button>
                );
              })}
            </div>
            {ruleReady && (
              <div className="pattern-panel" role="status">
                <div><small>{refined ? "RULE UPDATED FROM ONE CORRECTION" : `RULE FOUND FROM ${samples.length} EXAMPLES`}</small><h3>Stalled deliveries with repeat customer messages</h3><p>{refined ? "Leave out cases where a replacement or refund is already in progress. Priya and Omar were both removed." : "No tracking update for at least 3 days, and the customer has written more than once. Five cases appear to match."}</p></div>
                <button onClick={() => setApplied(!applied)}>{applied ? "BACK TO ALL 8" : `OPEN ${matches.length}-CASE REVIEW`}</button>
              </div>
            )}
          </PointerSurface>
        </BrowserFrame>
      </div>
      <DemoNotes tests="Can a pointer teach and correct a useful rule from examples instead of making the person build it field by field?" why={["The words do not have to match", "One negative example corrects unseen cases", "The rule and match count remain visible"]} failure="If people can describe or filter the rule faster, the brush is decoration." />
    </section>
  );
}

function TimefoldDemo({ onNext }: { onNext: () => void }) {
  const [open, setOpen] = useState(false);
  const [seats, setSeats] = useState(22);
  const [horizon, setHorizon] = useState(0);
  const [saved, setSaved] = useState(false);
  const [pointerLabel, setPointerLabel] = useState("OPEN TIMEFOLD");
  const savings = (25 - seats) * 28;

  const consequence = useMemo(() => {
    if (horizon === 0) return { title: "Today", value: "$0 charged", detail: seats === 25 ? "No seats are marked for removal. All 18 active members keep access." : `${25 - seats} unused seats would be marked for removal. All 18 active members keep access.` };
    if (horizon === 1) return { title: "Next invoice", value: `$${savings} saved`, detail: `The Sep 18 invoice falls from $700 to $${700 - savings}. No current member is removed.` };
    const gap = 22 - seats;
    return gap > 0
      ? { title: "In 90 days", value: `${gap} ${gap === 1 ? "seat" : "seats"} short`, detail: "At the current hiring rate, Design and Support would be unable to add every planned member in November." }
      : { title: "In 90 days", value: `${seats - 22} ${seats - 22 === 1 ? "seat" : "seats"} spare`, detail: "The reduced plan still covers 18 current members and 4 planned hires." };
  }, [horizon, savings, seats]);

  const reset = () => { setOpen(false); setSeats(22); setHorizon(0); setSaved(false); };

  return (
    <section className="prototype-page pointer-demo-page timefold-page">
      <PrototypeIntro number="03" dimension="TIME" title="Timefold" thesis="Point at a setting and drag forward through time. The pointer shows when the benefits and problems would actually appear." onNext={onNext} nextLabel="NEXT: SOURCE X-RAY" />
      <div className="prototype-stage">
        <DemoGuide text={!open ? "Point at the seat setting and open its future." : saved ? "The change is saved as a draft. The live plan is untouched." : "Change the seat count, then drag across Today, Next invoice, and 90 days."} onReset={reset} />
        <BrowserFrame title="Team plan">
          <PointerSurface className="time-workspace" label={pointerLabel} orbit={["●", "→", "90"]}>
            <header className="plan-header"><b>Northstar</b><nav>Overview <span>Plan</span> Invoices Team</nav><i>AK</i></header>
            <div className="plan-body">
              <div className="plan-title"><span>SETTINGS / PLAN</span><h2>Team plan</h2><p>Renews September 18</p></div>
              <button className={`seat-setting ${open ? "selected" : ""}`} onClick={() => setOpen(true)} onPointerEnter={() => setPointerLabel("SHOW FUTURE EFFECTS")}>
                <div><small>SEATS</small><strong>25</strong><span>18 active · 7 unused</span></div><b>$700<small>/month</small></b><em>{open ? "TIMEFOLD OPEN" : "POINT HERE"}</em>
              </button>
              <div className="plan-grid"><article><span>ACTIVE MEMBERS</span><b>18</b><p>14 employees · 4 contractors</p></article><article><span>PENDING INVITES</span><b>0</b><p>No access changes waiting</p></article><article><span>FORECAST</span><b>+4</b><p>Planned hires by November</p></article></div>
            </div>
            {open && (
              <div className="timefold-panel" role="dialog" aria-modal="false" aria-label="Future effects">
                <div className="timefold-head"><div><span>SIMULATING ONLY</span><h3>Reduce the plan to {seats} seats</h3></div><button onClick={() => setOpen(false)} aria-label="Close Timefold">×</button></div>
                <label className="seat-slider"><span>SEAT COUNT <b>{seats}</b></span><input type="range" min="18" max="25" value={seats} onChange={(event) => { setSeats(Number(event.target.value)); setSaved(false); }} /></label>
                <div className="time-rail"><input aria-label="Preview time" type="range" min="0" max="2" step="1" value={horizon} onChange={(event) => setHorizon(Number(event.target.value))} /><div><button onClick={() => setHorizon(0)} className={horizon === 0 ? "active" : ""}>TODAY</button><button onClick={() => setHorizon(1)} className={horizon === 1 ? "active" : ""}>NEXT INVOICE</button><button onClick={() => setHorizon(2)} className={horizon === 2 ? "active" : ""}>90 DAYS</button></div></div>
                <div className={`future-card future-${horizon}`} aria-live="polite"><span>{consequence.title}</span><strong>{consequence.value}</strong><p>{consequence.detail}</p></div>
                <button className="save-simulation" onClick={() => setSaved(true)}>{saved ? "✓ DRAFT SAVED" : "SAVE THIS AS A DRAFT CHANGE"}</button>
                <small>No plan, access, or billing changes have been made.</small>
              </div>
            )}
          </PointerSurface>
        </BrowserFrame>
      </div>
      <DemoNotes tests="Can the pointer turn a static setting into a clear view of consequences over time?" why={["The selected setting supplies the subject", "Horizontal movement controls time", "The live account remains untouched"]} failure="If the forecast is vague or slow, people will trust the ordinary settings page more." />
    </section>
  );
}

function SourceXRayDemo({ onNext }: { onNext: () => void }) {
  const [open, setOpen] = useState(false);
  const [depth, setDepth] = useState(0);
  const [selectedSource, setSelectedSource] = useState<"contracts" | "churn" | "fx" | null>(null);
  const [updated, setUpdated] = useState(false);
  const [drafted, setDrafted] = useState(false);
  const [pointerLabel, setPointerLabel] = useState("SHOW SOURCES");
  const displayed = updated ? "$1.76M" : "$1.84M";
  const reset = () => { setOpen(false); setDepth(0); setSelectedSource(null); setUpdated(false); setDrafted(false); };

  return (
    <section className="prototype-page pointer-demo-page xray-page">
      <PrototypeIntro number="04" dimension="EVIDENCE" title="Source X-Ray" thesis="Point at a claim and see the files, records, and adjustments behind it. Change a source in preview and watch the claim update." onNext={onNext} nextLabel="NEXT: AFTERIMAGE" />
      <div className="prototype-stage">
        <DemoGuide text={!open ? "Point at Renewal revenue and pull its source trail open." : depth < 2 ? "Pull deeper: meaning, calculation, then sources." : updated ? "The preview now uses the newer churn file. Draft a correction or switch it back." : "Open the stale churn source, then preview the current file."} onReset={reset} />
        <BrowserFrame title="Revenue dashboard" tone="dark">
          <PointerSurface className="xray-workspace" label={pointerLabel} orbit={["?", "ƒ", "≣"]}>
            <header className="analytics-header"><div><i>R</i><b>Rill Analytics</b></div><nav>Overview <span>Revenue</span> Customers Forecast</nav><em>Q3 LIVE</em></header>
            <div className="analytics-body">
              <div className="analytics-title"><span>REVENUE / RENEWALS</span><h2>Quarter outlook</h2><p>Last refreshed 8 minutes ago</p></div>
              <div className="metric-grid">
                <button className={`metric-card primary ${open ? "xray-open" : ""}`} onClick={() => { setOpen(true); setDepth(0); }} onPointerEnter={() => setPointerLabel("PULL APART THIS NUMBER")}><span>RENEWAL REVENUE</span><strong>{displayed}</strong><p>Expected this quarter</p><em>{open ? "X-RAY OPEN" : "POINT TO CHECK"}</em></button>
                <article className="metric-card"><span>RENEWAL RATE</span><strong>84.2%</strong><p>−1.8 pts from Q2</p></article>
                <article className="metric-card"><span>AT RISK</span><strong>$286K</strong><p>17 customer accounts</p></article>
              </div>
              <div className="revenue-chart"><span style={{ height: "46%" }} /><span style={{ height: "58%" }} /><span style={{ height: "54%" }} /><span style={{ height: "73%" }} /><span style={{ height: "68%" }} /><span style={{ height: "82%" }} /><i>JUL</i><i>AUG</i><i>SEP</i></div>
            </div>
            {open && (
              <div className="xray-panel" role="dialog" aria-modal="false" aria-label="Source trail">
                <div className="xray-head"><div><span>SOURCE TRAIL</span><h3>Why does this say {displayed}?</h3></div><button onClick={() => setOpen(false)} aria-label="Close source trail">×</button></div>
                <div className="xray-depth">
                  <label><span>PULL DEEPER</span><input aria-label="X-ray depth" type="range" min="0" max="3" step="1" value={depth} onChange={(event) => setDepth(Number(event.target.value))} /></label>
                  <div><button className={depth === 0 ? "active" : ""} onClick={() => setDepth(0)}>MEANING</button><button className={depth === 1 ? "active" : ""} onClick={() => setDepth(1)}>CALCULATION</button><button className={depth === 2 ? "active" : ""} onClick={() => setDepth(2)}>SOURCES</button><button className={depth === 3 ? "active" : ""} onClick={() => setDepth(3)}>RECORDS</button></div>
                </div>
                <div className="meaning-layer"><span>MEANING</span><p>Expected renewal revenue for signed contracts in Q3, after known churn and currency adjustments.</p></div>
                {depth >= 1 && <div className="formula-layer"><span>CALCULATION</span><p><b>$1.92M</b> signed contracts <i>−</i> <b>{updated ? "$160K" : "$80K"}</b> known churn <i>+</i> <b>$0</b> currency adjustment <i>=</i> <strong>{displayed}</strong></p></div>}
                {depth >= 2 && <div className="source-stack">
                  <button className="source-good" onClick={() => { setSelectedSource("contracts"); setDepth(3); }}><i>CRM</i><span><b>Signed renewal contracts</b><small>Updated 8 min ago · 42 records</small></span><strong>+$1.92M</strong></button>
                  <button className={updated ? "source-good" : "source-stale"} onClick={() => { setSelectedSource("churn"); setDepth(3); }}><i>CSV</i><span><b>{updated ? "Churn export · Jul 10" : "Churn export · Jun 28"}</b><small>{updated ? "Current file · 9 records" : "12 days old · newer file available"}</small></span><strong>{updated ? "−$160K" : "−$80K"}</strong></button>
                  <button className="source-good" onClick={() => { setSelectedSource("fx"); setDepth(3); }}><i>FX</i><span><b>Currency adjustment</b><small>Updated today · ECB rate</small></span><strong>$0</strong></button>
                </div>}
                {depth >= 3 && <div className="record-layer">
                  <span>RECORDS · {selectedSource ? selectedSource.toUpperCase() : "CHOOSE A SOURCE"}</span>
                  {selectedSource === "churn" ? <><p><b>Northwind</b><i>Non-renewal confirmed Jul 8</i><strong>−$52K</strong></p><p><b>Papertrail</b><i>Downgrade confirmed Jul 9</i><strong>−$28K</strong></p><p><b>7 more records</b><i>Current churn export</i><strong>−$80K</strong></p><button onClick={() => { setUpdated(!updated); setDrafted(false); }}>{updated ? "USE THE JUN 28 FILE AGAIN" : "PREVIEW THE CURRENT JUL 10 FILE"}</button></> : <p className="record-prompt">Choose a source above to inspect the records behind its part of the total.</p>}
                </div>}
                {depth >= 1 && <div className={`xray-total ${updated ? "changed" : ""}`}><span>PREVIEWED TOTAL</span><b>{displayed}</b><p>{updated ? "The current churn file lowers the total by $80K." : depth >= 2 ? "The dashboard is using a stale churn file." : "The formula still uses the Jun 28 churn export."}</p></div>}
                {depth >= 2 && (!drafted ? <button className="draft-correction" onClick={() => setDrafted(true)} disabled={!updated}>DRAFT A DASHBOARD CORRECTION</button> : <div className="correction-note"><span>DRAFT ONLY</span><p>Update Renewal revenue to $1.76M using Churn export · Jul 10. Keep the previous value in the audit log.</p></div>)}
              </div>
            )}
          </PointerSurface>
        </BrowserFrame>
      </div>
      <DemoNotes tests="Can pointing at a visible claim make its full source trail understandable and correctable?" why={["The number supplies the question", "Sources stay next to the claim", "Changes remain a preview"]} failure="If source links are already clear or the trail cannot be trusted, the x-ray adds visual noise." />
    </section>
  );
}

const afterSteps = [
  { label: "Open the receipt", detail: "Adobe · $58.99", key: "open" },
  { label: "Choose Software", detail: "Category", key: "category" },
  { label: "Attach the PDF", detail: "Adobe-Receipt.pdf", key: "attach" },
  { label: "Save as draft", detail: "Never submit", key: "save" },
];

function AfterimageDemo({ onNext }: { onNext: () => void }) {
  const [step, setStep] = useState(0);
  const [saved, setSaved] = useState(false);
  const [targetOpen, setTargetOpen] = useState(false);
  const [replayed, setReplayed] = useState(false);
  const [pointerLabel, setPointerLabel] = useState("DO THE NEXT STEP");
  const reset = () => { setStep(0); setSaved(false); setTargetOpen(false); setReplayed(false); };
  const doStep = (index: number) => { if (index === step) setStep(index + 1); };

  return (
    <section className="prototype-page pointer-demo-page afterimage-page">
      <PrototypeIntro number="05" dimension="MEMORY" title="Afterimage" thesis="Do a normal task once. After it is finished, the pointer offers a shorter path for the next similar item—without asking for a teaching session." onNext={onNext} nextLabel="BACK TO FIELD NOTE" />
      <div className="prototype-stage">
        <DemoGuide text={replayed ? "The second draft was prepared in one action. Undo or reset to try again." : saved && targetOpen ? "The matching receipt is open. Use the pointer action that appeared beside it." : saved ? "The shortcut is ready. Open the Dropbox receipt." : step === 4 ? "The path is complete. Decide whether to keep the shortcut." : `Complete step ${step + 1}. The pointer is remembering the path in this demo only.`} onReset={reset} />
        <BrowserFrame title="Expense inbox" tone="violet">
          <PointerSurface className="after-workspace" label={pointerLabel} orbit={["1", "↻", "✓"]}>
            <header className="expense-header"><b>Ledgerly</b><nav><span>Inbox</span> Reports Vendors</nav><em>LOCAL MEMORY · THIS DEMO ONLY</em><button>＋ New expense</button><i>MO</i></header>
            <div className="expense-layout">
              <aside className="expense-inbox"><div><b>Receipt inbox</b><span>12 unread</span></div><button className={!targetOpen ? "active" : ""} onClick={() => doStep(0)} onPointerEnter={() => setPointerLabel(step === 0 ? "OPEN RECEIPT" : "ALREADY DONE")}><i>A</i><span><b>Adobe</b><small>Creative Cloud · PDF attached</small></span><strong>$58.99</strong></button><button className={targetOpen ? "active" : ""} onClick={() => { if (saved) { setTargetOpen(true); setPointerLabel("SHORTER PATH READY"); } }} disabled={!saved}><i>D</i><span><b>Dropbox</b><small>Team storage · PDF attached</small></span><strong>$24.00</strong></button></aside>
              <section className="expense-receipt"><span>RECEIPT</span><h2>{targetOpen ? "Dropbox" : "Adobe"}</h2><strong>{targetOpen ? "$24.00" : "$58.99"}</strong><p>{targetOpen ? "Team storage" : "Creative Cloud All Apps"}</p><div>PDF ATTACHED · TODAY</div></section>
              <aside className="expense-form"><span>EXPENSE DRAFT</span><label>Vendor<input readOnly value={targetOpen ? "Dropbox" : "Adobe"} /></label><button className={step === 1 ? "next" : step > 1 ? "done" : ""} onClick={() => doStep(1)} disabled={step < 1 || saved}>Category <b>{step > 1 || targetOpen ? "Software ✓" : "Choose…"}</b></button><button className={step === 2 ? "next" : step > 2 ? "done" : ""} onClick={() => doStep(2)} disabled={step < 2 || saved}>Receipt <b>{step > 2 || targetOpen ? "PDF attached ✓" : "Attach file"}</b></button><button className={`save-expense ${step === 3 ? "next" : ""}`} onClick={() => doStep(3)} disabled={step < 3 || saved}>{step > 3 || replayed ? "✓ DRAFT READY" : "SAVE DRAFT"}</button></aside>
            </div>
            <div className="afterimage-trail" aria-label="Remembered pointer path">{afterSteps.map((item, index) => <div key={item.key} className={index < step ? "done" : index === step ? "current" : ""}><i>{index < step ? "✓" : index + 1}</i><span><b>{item.label}</b><small>{item.detail}</small></span></div>)}</div>
            {step === 4 && !saved && <div className="shortcut-offer"><span>PATH NOTICED</span><h3>You finished this path. It also appeared twice earlier this week.</h3><p>Add “Prepare expense draft” to the pointer for matching receipts?</p><div><button onClick={reset}>NOT NOW</button><button onClick={() => setSaved(true)}>ADD THE SHORTCUT</button></div></div>}
            {saved && targetOpen && !replayed && <button className="saved-pointer-action" onClick={() => setReplayed(true)} onPointerEnter={() => setPointerLabel("PREPARE DRAFT")}><span>✦</span><div><b>Prepare expense draft</b><small>Dropbox · use the four saved steps</small></div><em>ONE ACTION</em></button>}
            {replayed && <div className="replay-toast"><span>✓</span><div><b>Dropbox draft prepared</b><p>4 saved steps · source PDF attached · nothing submitted</p></div><button onClick={() => setReplayed(false)}>UNDO</button></div>}
          </PointerSurface>
        </BrowserFrame>
      </div>
      <DemoNotes tests="Can the pointer offer automation only after normal work proves that the path is useful?" why={["No setup before the first success", "Only a completed path can become a shortcut", "The next run is one deliberate, reversible action"]} failure="If the offer appears too early or remembers the wrong path, it becomes an interruption instead of help." />
    </section>
  );
}
