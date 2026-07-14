we are interested in building a chrome extension that uses content scripts to inject a magical ui in every page, where the magic is just access to an LLM, but this work is not about the LLM or how the magic is
actually conducted, its first and foremost about UI and UX, we are after the state of the art in browser chat agents from "what the users sees" and "how does it delight the user". we expect the result of this work
to end with a report and 3 radically different contributions to the thinking here we want you to go above and beyond what many people would consider reasonable or possible to showcase what can be done.

a starting place for what might be the state of the art. s starting place if you will:
0. 'page-agent' https://github.com/alibaba/page-agent
1. `gui-agent`: in-page tool registry and visualizer.
2. Notte: workflow-session dry-run corpus with reliability metrics.
3. Stagehand / Playwright MCP: proof harnesses and structured page-state inspection.
4. Magentic UI: approval, takeover, and progress UX.
5. googles disco browser: https://blog.google/innovation-and-ai/models-and-research/google-labs/gentabs-gemini-3/
6. https://github.com/microsoft/webwright

non-agentic ui inspiration:

https://github.com/GoogleChromeLabs/ProjectVisBug

do not consider the above list exhaustive -- we only wanted to give you a place to start. your boundary is:  you can mock an llm, mock data, even mock websites to showcase interesting and novel ideas and ux. there are others who have tried this and failed, but much has changed and is rapidly changing:
the openai atlas browser, perplexities comet browser, and The Browser Company's Dia all failed. users dont always know what they want to automate or hand over in a browser. simply attaching a chat box and a pages
dom to an agent and a LLM -- has proven to be a failure because a) humans dont trust it, b) its slower than humans, c) the guardrails added reduce the utility (claude-chrome wont help me make a transfer on paypal.com) 

ingredients you can use: chrome extension, native apps, cloud proxy/backend, any aws/azure cloud capability. this mac has 128GB and an M5 chip -- and again we do not want you to veer too far in the agent/harness REPL / loop / toolcalling / fine tuning space, this is a ux / ui adventure. we have some light research docs you can review in ~/practical_

~/ practical_take_v2_implementation_spec.md  practical_take_v2.md                      practical_take.md
