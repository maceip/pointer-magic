"use client";

import { useEffect, useMemo, useState } from "react";

type View = "report" | "halo" | "shadow" | "loom";

const navItems: { id: View; label: string; short: string }[] = [
  { id: "report", label: "Field report", short: "00" },
  { id: "halo", label: "Intent Halo", short: "01" },
  { id: "shadow", label: "Shadow Run", short: "02" },
  { id: "loom", label: "Apprentice Relay", short: "03" },
];

const evidence = [
  {
    name: "ChatGPT Atlas",
    move: "Contextual assistant + opt-in agent mode",
    lesson: "Native context removes copy/paste, but the user still starts with a prompt.",
    href: "https://openai.com/index/introducing-chatgpt-atlas/",
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
    lesson: "Skills make intent repeatable; draft-first effects are a strong trust primitive.",
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
    lesson: "The highest-leverage output may be a new interface, not automated clicks.",
    href: "https://blog.google/innovation-and-ai/models-and-research/google-labs/gentabs-gemini-3/",
  },
  {
    name: "Page Agent + VisBug",
    move: "In-page action + direct manipulation",
    lesson: "An injected layer can feel native when it points at the work instead of opening a cockpit.",
    href: "https://github.com/alibaba/page-agent",
  },
];

const laws = [
  ["Offer verbs before a blank box", "Reveal useful intents from selection, page state, and recent work."],
  ["Transform, don’t narrate", "Prefer a comparison, diff, or tool the user can manipulate over a paragraph."],
  ["Separate thought from effect", "Exploration is cheap; a state-changing boundary is explicit and inspectable."],
  ["Approve consequences, not steps", "One compact contract beats permission fatigue on every click."],
  ["Make waiting compound", "If the machine is slower, it must compare, synthesize, or parallelize—not imitate a cursor."],
  ["Show evidence, not hidden reasoning", "Expose sources, scope, confidence, and receipts without pretending to reveal a mind."],
  ["Keep progress honest", "Measured stages, indeterminate work, and named errors—never decorative percentages."],
  ["Leave the page better than you found it", "Every intervention is reversible, dismissible, and respectful of the host UI."],
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
          The interface has to help people discover what is worth delegating, understand what will change,
          and get leverage that is visibly faster than doing it themselves.
        </p>
        <div className="hero-thesis">
          <div><span>OLD CENTER</span><strong>Prompt → watch clicks → hope</strong></div>
          <b aria-hidden="true">→</b>
          <div><span>NEW CENTER</span><strong>Intent → artifact → commit</strong></div>
        </div>
        <div className="scroll-cue">SCROLL THE ARGUMENT <span>↓</span></div>
      </section>

      <section className="failure-strip" aria-label="Failure modes">
        <div><span>01</span><strong>Unknown intent</strong><p>A blank prompt asks the user to design the product’s value.</p></div>
        <div><span>02</span><strong>Invisible risk</strong><p>“Working…” conceals the line between reading and changing.</p></div>
        <div><span>03</span><strong>Cursor theater</strong><p>Watching serial clicks is slower and less legible than doing them.</p></div>
        <div><span>04</span><strong>Guardrail tax</strong><p>Repeated permission prompts make safety feel like broken utility.</p></div>
      </section>

      <section className="report-section state-section">
        <div className="section-kicker">01 / THE STATE OF THE ART</div>
        <div className="section-heading">
          <h2>The pieces are good.<br />The center is wrong.</h2>
          <p>
            Current systems have discovered valuable primitives—context, skills, plan editing, approval,
            provenance, session replay, and generated apps. Most still orbit a conversation window.
          </p>
        </div>
        <div className="evidence-grid">
          {evidence.map((item, index) => (
            <a href={item.href} target="_blank" rel="noreferrer" key={item.name} className="evidence-card">
              <span className="evidence-index">0{index + 1}</span>
              <strong>{item.name}</strong>
              <em>{item.move}</em>
              <p>{item.lesson}</p>
              <Arrow />
            </a>
          ))}
        </div>
        <p className="inference-note">
          <strong>Inference:</strong> the winning browser layer will borrow control from Magentic-UI, directness
          from VisBug, provenance from GenTabs, and reusable artifacts from Webwright—without making any one
          of their interfaces the whole product.
        </p>
      </section>

      <section className="report-section laws-section">
        <div className="section-kicker">02 / DESIGN LAWS</div>
        <div className="section-heading inverted">
          <h2>Eight rules for<br />an agent people keep.</h2>
          <p>
            These turn “trust” and “delight” into visible interface behavior. They draw on current product
            patterns and human-AI guidance around capability, correction, scope, explanation, and control.
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
        <div className="section-kicker">03 / THREE PRODUCT BETS</div>
        <div className="section-heading">
          <h2>Not skins.<br />Different physics.</h2>
          <p>
            Each prototype chooses a different moment for intelligence to enter the page. The goal is not
            to select a winner yet; it is to make the strategic options concrete enough to argue with.
          </p>
        </div>
        <div className="prototype-cards">
          <button onClick={() => onOpen("halo")} className="prototype-card halo-card">
            <span>01 · INVOKE</span>
            <div className="mini-halo"><i /><b>compare</b><i /></div>
            <h3>Intent Halo</h3>
            <p>The page offers contextual verbs at the object of attention. No prompt required.</p>
            <em>Solves: “I don’t know what to ask.”</em>
            <strong>OPEN PROTOTYPE <Arrow /></strong>
          </button>
          <button onClick={() => onOpen("shadow")} className="prototype-card shadow-card">
            <span>02 · DELEGATE</span>
            <div className="mini-shadow"><i /><i /><i /><b>COMMIT</b></div>
            <h3>Shadow Run</h3>
            <p>The agent rehearses in a twin state, then presents one bounded, reviewable change.</p>
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
        <div className="section-kicker">04 / DECISION FRAME</div>
        <h2>Ship the boundary first.</h2>
        <div className="decision-table">
          <div className="table-head"><span>BET</span><span>BEST FIRST TASK</span><span>MOAT</span><span>EARLY RISK</span></div>
          <div><strong>Intent Halo</strong><span>Compare / explain / extract on one page</span><span>Contextual invocation</span><span>Suggestion noise</span></div>
          <div><strong>Shadow Run</strong><span>Forms, settings, drafts, account changes</span><span>Trust + receipts</span><span>Twin-state fidelity</span></div>
          <div><strong>Apprentice Relay</strong><span>Repetitive work with meaningful exceptions</span><span>Learning by demonstration</span><span>Bad generalization</span></div>
        </div>
        <div className="recommendation">
          <span>RECOMMENDED SEQUENCE</span>
          <p><b>Start with Intent Halo’s invocation</b>, route any state-changing verb through <b>Shadow Run’s
          contract</b>, then use <b>Apprentice Relay</b> to turn repeated safe work into an editable recipe.</p>
        </div>
      </section>

      <footer className="report-footer">
        <Mark />
        <p>AFTER CHAT · A UI/UX RESEARCH PROTOTYPE<br />Mocks intelligence. Tests interaction.</p>
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

function HaloDemo({ onNext }: { onNext: () => void }) {
  const [stage, setStage] = useState<"idle" | "verbs" | "compare" | "chosen">("idle");
  const [arrival, setArrival] = useState(72);
  const [quiet, setQuiet] = useState(64);
  const [bags, setBags] = useState(true);

  const winner = useMemo(() => {
    if (arrival > 78) return { airline: "Northstar", detail: "lands at 18:10 · 1 stop", price: "$842" };
    if (quiet > 72) return { airline: "Arc Air", detail: "quiet cabin · nonstop", price: "$918" };
    if (bags) return { airline: "Morrow", detail: "2 bags included · nonstop", price: "$884" };
    return { airline: "Lumen", detail: "best fare · nonstop", price: "$776" };
  }, [arrival, quiet, bags]);

  return (
    <section className="prototype-page halo-page">
      <PrototypeIntro
        number="01"
        title="Intent Halo"
        thesis="Intelligence appears as contextual verbs around the thing you are already looking at. The user points; the interface proposes leverage."
        onNext={onNext}
        nextLabel="NEXT: SHADOW RUN"
      />
      <div className="prototype-stage">
        <div className="stage-instruction">
          <span>TRY IT</span>
          <p>{stage === "idle" ? "Open the halo on the highlighted flight result." : stage === "verbs" ? "Choose “compare for me.”" : stage === "compare" ? "Adjust what matters; the page re-ranks live." : "The choice is applied, with every reason still visible."}</p>
          <button onClick={() => { setStage("idle"); setArrival(72); setQuiet(64); setBags(true); }}>RESET</button>
        </div>
        <BrowserFrame title="Flight search">
          <div className="travel-site">
            <header className="travel-header"><b>wayfare</b><nav>Explore <span>Trips</span> Stays</nav><div className="avatar">MC</div></header>
            <div className="search-summary"><span>SFO</span><b>→</b><span>CPH</span><i>Sep 12–20 · 1 traveler · Economy</i><button>Change</button></div>
            <div className="results-layout">
              <aside><strong>Filters</strong><label>Stops <span>Any</span></label><label>Departure <span>Morning</span></label><label>Bags <span>1+</span></label><div className="ad-block" /></aside>
              <section className="flight-results">
                <div className="result-meta"><strong>24 results</strong><span>Sorted by Recommended⌄</span></div>
                {[{airline:"Lumen",time:"17:20",price:"$776",meta:"nonstop · 10h 40m"},{airline:"Morrow",time:"18:40",price:"$884",meta:"nonstop · 10h 55m"},{airline:"Arc Air",time:"19:15",price:"$918",meta:"nonstop · quiet cabin"}].map((flight, index) => (
                  <div className={`flight-card ${index === 1 ? "focus-flight" : ""} ${stage === "chosen" && flight.airline === winner.airline ? "selected-flight" : ""}`} key={flight.airline}>
                    <div className="airline-logo">{flight.airline[0]}</div>
                    <div><strong>{flight.airline}</strong><span>{flight.meta}</span></div>
                    <div><strong>{flight.time}</strong><span>arrives +1</span></div>
                    <div><strong>{flight.price}</strong><span>round trip</span></div>
                    {index === 1 && stage === "idle" && <button className="halo-trigger" onClick={() => setStage("verbs")} aria-label="Open Intent Halo"><span>✦</span><i /></button>}
                  </div>
                ))}
              </section>
            </div>

            {stage === "verbs" && (
              <div className="halo-menu">
                <div className="halo-center">✦</div>
                <button className="halo-verb verb-one" onClick={() => setStage("compare")}><b>Compare for me</b><span>use what I care about</span></button>
                <button className="halo-verb verb-two"><b>Explain the catch</b><span>fees, layovers, timing</span></button>
                <button className="halo-verb verb-three"><b>Watch this price</b><span>alert only if meaningful</span></button>
                <button className="halo-close" onClick={() => setStage("idle")}>×</button>
              </div>
            )}

            {(stage === "compare" || stage === "chosen") && (
              <div className="preference-sheet">
                <div className="sheet-top"><span>✦ LIVE COMPARISON</span><button onClick={() => setStage("idle")}>×</button></div>
                <h3>What makes a flight good <em>for you?</em></h3>
                <p>Move the priorities. Results update in place—nothing is booked.</p>
                <label><span><b>Arrive before dinner</b><i>{arrival}%</i></span><input type="range" min="0" max="100" value={arrival} onChange={(event) => { setArrival(Number(event.target.value)); setStage("compare"); }} /></label>
                <label><span><b>Quiet, low-stress cabin</b><i>{quiet}%</i></span><input type="range" min="0" max="100" value={quiet} onChange={(event) => { setQuiet(Number(event.target.value)); setStage("compare"); }} /></label>
                <button className={`toggle-row ${bags ? "on" : ""}`} onClick={() => { setBags(!bags); setStage("compare"); }}><span><b>Include the real bag price</b><i>Uses each airline’s current rules</i></span><em><i /></em></button>
                <div className="live-winner"><span>BEST FIT NOW</span><div><b>{winner.airline}</b><p>{winner.detail}</p><strong>{winner.price}</strong></div></div>
                <button className="apply-choice" onClick={() => setStage("chosen")}>{stage === "chosen" ? "✓ APPLIED TO RESULTS" : "APPLY THIS LENS"}</button>
                <small>Why this ranking? 3 preferences · 24 results · current fare data</small>
              </div>
            )}
            {stage === "chosen" && <div className="page-toast"><span>✓</span><div><b>Lens applied</b><p>Results now reflect your priorities. Clear anytime.</p></div><button onClick={() => setStage("idle")}>UNDO</button></div>}
          </div>
        </BrowserFrame>
      </div>
      <ConceptNotes
        thesis="Invocation becomes direct manipulation. The model’s first job is not answering; it is naming useful verbs at the right object."
        wins={["No prompt literacy", "Host page stays primary", "Read-only by default", "Preference learning is visible"]}
        risk="Bad suggestions become visual spam. The halo must be rare, precise, and summoned—not ambient confetti."
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
        thesis="The agent gets a rehearsal state, not your live state. It returns a compact contract, a diff, and one commit boundary."
        onNext={onNext}
        nextLabel="NEXT: CONTEXT LOOM"
      />
      <div className="prototype-stage">
        <div className="stage-instruction shadow-instruction">
          <span>TRY IT</span>
          <p>{step === 0 ? "Run the rehearsal. It cannot touch the live account." : step < 4 ? "Watch the measured stages—not simulated cursor movement." : committed ? "The exact approved change is now committed, with a receipt." : "Review the diff, change the boundary, then commit once."}</p>
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
                      <button className={`contract-toggle ${keepExport ? "on" : ""}`} onClick={() => setKeepExport(!keepExport)}><span><b>Hard boundary</b><small>Never alter Advanced exports</small></span><em><i /></em></button>
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
        thesis="Approval moves from step-level interruption to transaction-level escrow. The user approves a consequence they can understand."
        wins={["No permission fatigue", "No cursor theater", "Explicit non-goals", "Receipts + undo"]}
        risk="The twin must faithfully model live effects. When it cannot, the interface must downgrade from “rehearsed” to “proposed.”"
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
          <p>{phase === 0 ? "Teach with one receipt instead of writing a perfect prompt." : phase === 1 ? "Finish the example; every demonstrated boundary is visible." : phase === 2 ? "Edit the learned stop rules before anything repeats." : phase === 3 ? "Preview how 11 receipts split between the assistant and you." : "Approve the safe lane while exceptions remain yours."}</p>
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
        thesis="Intent is taught by example, then compressed into a visible contract. The assistant handles the repetitive majority while the human works exceptions in parallel."
        wins={["No prompt specification", "Human + assistant concurrency", "Visible generalization", "Guardrails route instead of refuse"]}
        risk="One example can encode accidental behavior. Preview, editable stop rules, and source-linked reconciliation are mandatory."
      />
    </section>
  );
}

function ConceptNotes({ thesis, wins, risk }: { thesis: string; wins: string[]; risk: string }) {
  return (
    <div className="concept-notes">
      <div><span>PRODUCT THESIS</span><p>{thesis}</p></div>
      <div><span>WHAT IT EARNS</span><ul>{wins.map((win) => <li key={win}>↳ {win}</li>)}</ul></div>
      <div><span>WHAT COULD KILL IT</span><p>{risk}</p></div>
    </div>
  );
}
