# Research Sequence 10: Market Productization

## Overview

Cascade's current product is differentiated by the combination of a local-first work memory, proof-backed rewind, learned repetitive-work detection, and supervised real-screen/browser computer use. That is not the same category as enterprise search, RPA, or browser agents, but it overlaps with all three.

The production-grade bar is therefore higher than "the agent works in a demo." Enterprise buyers will evaluate Cascade as software that records employee work context, touches sensitive application surfaces, and can execute actions on behalf of users. The product must clear the buyer's security, identity, deployment, governance, legal, labor-relations, and reliability checks before it can be treated as a platform rather than a clever desktop tool.

The market opening is real. Incumbents are moving from passive AI assistants to governed agent platforms: Glean sells a Work AI platform with agents, governance, observability, 275+ connectors, single-tenant/BYOC options, regional residency, and sensitive-data controls ([Glean Agents](https://www.glean.com/product/ai-agents), [Glean Security](https://www.glean.com/security), [Glean Connectors](https://www.glean.com/connectors)); UiPath and Automation Anywhere now frame RPA as "agentic automation" that combines agents, robots, people, orchestration, and compliance ([UiPath Platform](https://www.uipath.com/product), [Automation Anywhere](https://www.automationanywhere.com/)); Microsoft Recall validates local screen memory as a platform primitive, but also shows how high the privacy and admin-control bar is ([Microsoft Learn: Manage Recall](https://learn.microsoft.com/en-us/windows/client-management/manage-recall), [Recall security architecture](https://blogs.windows.com/windowsexperience/2024/09/27/update-on-recall-security-and-privacy-architecture/)).

The risk is equally real. Recent employee-tracking controversies, including Meta pausing a computer-activity tracking program after worker privacy concerns, show that "recording employee screens/keystrokes for AI" is radioactive when positioned as employer surveillance ([Guardian](https://www.theguardian.com/technology/2026/jun/24/meta-pauses-employee-tracker-for-ai-training-amid-privacy-concerns), [Wired](https://www.wired.com/story/meta-accidentally-let-employees-access-each-others-keystroke-data)). Cascade's market-fit depends on employee agency: local capture, visible pause/stop, employee review, transparent exclusions, and manager views that aggregate automation opportunity rather than score individuals.

## Competitive Landscape

| Product | Positioning | Strength | Gap-vs-Cascade |
|---|---|---|---|
| Microsoft Recall | OS-level local "photographic memory" for Copilot+ PCs; snapshots are locally stored/analyzed, opt-in, encrypted, and policy-managed on commercial devices ([Manage Recall](https://learn.microsoft.com/en-us/windows/client-management/manage-recall)). | OS distribution, local processing, enterprise policies for enablement, storage, retention, app/site filtering, DLP, and EEA export. | Windows-only and memory/search-first; no learned workflow-to-agent layer, no macOS-native automation, and no employee-reviewed automation marketplace. It sets the admin/privacy standard Cascade must match. |
| Limitless / Rewind | Personal memory/wearable lifelog product. Limitless says it was acquired by Meta, Pendant sales stopped, existing users get free Unlimited, web/desktop recording is disabled, and Rewind is sunsetting ([Limitless](https://www.limitless.ai/)). | Strong consumer memory narrative, data export/delete UX, consent language, API/MCP access to lifelogs ([Limitless Privacy](https://www.limitless.ai/privacy), [Developers](https://www.limitless.ai/developers)). | No longer a durable standalone competitor in desktop work recording; audio/meeting memory rather than enterprise on-screen automation. Leaves a gap for enterprise local work memory if Cascade avoids the privacy pitfalls. |
| Glean | Enterprise "Work AI" platform: search, assistant, agents, orchestration, governance, connectors, and observability ([Glean Agents](https://www.glean.com/product/ai-agents)). | Permission-aware enterprise graph, 275+ connectors, agent sharing controls, action guardrails, observability, sensitive-data policies, single-tenant/BYOC and data sovereignty options ([Agent Governance](https://www.glean.com/product/agent-governance), [Security](https://www.glean.com/security)). | Cloud connector/search-first; does not observe real desktop workflows or learn from screen-level work traces. Cascade lacks Glean's enterprise admin, connectors, BYOC, governance, and observability. |
| UiPath | Mature enterprise automation platform evolving from RPA to agentic automation: "agents think, robots do, people lead" ([UiPath Platform](https://www.uipath.com/product)). | Enterprise sales motion, robots, Studio, Orchestrator/Maestro, process mining, testing, marketplace, support, certifications, and pricing packages ([UiPath Pricing](https://www.uipath.com/pricing)). | Heavy implementation and process-design motion; strong for known structured workflows, weaker for discovering personal repetitive work from local evidence. Cascade must prove reliability before it can challenge RPA in production workflows. |
| Automation Anywhere | Agentic Process Automation platform with Process Reasoning Engine, AI Agent Studio, governance, and prebuilt industry solutions ([Automation Anywhere](https://www.automationanywhere.com/)). | Enterprise credibility, certifications/trust center, prebuilt solutions, RPA installed base, claims around straight-through processing and auto-resolution. | Similar to UiPath: better enterprise packaging, weaker local-first work-memory wedge. Cascade must add compliance/admin depth while staying lighter and more employee-trusted. |
| OpenAI Operator / ChatGPT Agent | Browser-using agent research preview, integrated into ChatGPT agent mode; CUA interacts with webpages by screenshots, typing, clicking, and scrolling ([Introducing Operator](https://openai.com/index/introducing-operator/)). | Model quality, broad developer ecosystem, safety layers for takeover, confirmations, sensitive-task limitations, and prompt-injection monitoring ([Computer-Using Agent](https://openai.com/index/computer-using-agent/)). | Browser-centric and cloud-hosted; not an enterprise local work recorder, not macOS-native, and not learning workflows from employee history. It raises user expectations for browser agents. |
| Claude for Chrome | Research preview letting Claude take actions in Chrome for trusted testers; Anthropic explicitly warns about prompt-injection risk and sensitive sites ([Claude for Chrome](https://www.anthropic.com/news/claude-for-chrome)). | Strong browser co-pilot model, explicit safety framing, permission-control learning loop. | Browser-only pilot. Cascade can differentiate with local app coverage, audit-first STOP controls, and learned workflow replay, but must match prompt-injection and permission rigor. |
| Salesforce Agentforce / CRM agents | CRM-native agent platform. Public reporting suggests Salesforce moved toward predictable per-user AI pricing after experimenting with per-conversation pricing ([TechRadar](https://www.techradar.com/pro/salesforce-says-per-user-pricing-will-be-new-ai-norm)). | Deep CRM workflow distribution, data gravity, enterprise procurement muscle, vertical templates. | Department/platform-specific. Cascade's wedge is cross-app personal work discovery, but it will need connectors into systems like Salesforce rather than competing as a CRM agent platform. |
| "AI employee" startups such as Artisan, Lindy, Relevance AI | Sell specialized digital workers for sales, support, recruiting, ops, or no-code agent teams. Artisan's "Stop Hiring Humans" campaign shows the category's provocative GTM risk ([Artisan background](https://en.wikipedia.org/wiki/Artisan_AI)). | Clear job-to-be-done packaging, fast demos, outcome language, vertical workflows. | Often cloud/API/browser-flow based and prone to job-replacement backlash. Cascade should avoid replacement language and sell employee-owned automation leverage. |

## Enterprise Buyer Requirements Checklist

### Security, Compliance, and Legal

- SOC 2 Type II at minimum; ISO 27001 is table stakes for larger buyers, and ISO 42001/AI governance is becoming valuable where agents make or recommend actions. Automation Anywhere prominently markets SOC 1/SOC 2, ISO 27001, ISO 42001, HIPAA, and HITRUST signals ([Automation Anywhere](https://www.automationanywhere.com/)).
- DPA, subprocessors, data-flow diagrams, privacy policy, breach notification terms, retention/deletion guarantees, customer data ownership, and model-training opt-out/zero-retention terms.
- Annual third-party penetration test, vulnerability disclosure/bug bounty path, secure SDLC evidence, responsible-AI risk assessment, and admin-facing security documentation.
- Works-council/employee-notice deployment kit: what is captured, what is never captured, who can see what, how to pause, how to delete/export, and how manager analytics are aggregated.

### Identity, Admin, and Governance

- SAML/OIDC SSO, SCIM provisioning/deprovisioning, domain claim, role-based access control, groups, workspace/tenant model, admin console, audit-admin role, and license/seat management.
- Org-level policies for recording availability, app/site exclusions, sensitive-data exclusions, retention windows, local storage caps, export permissions, agent action classes, and power-tool availability. Microsoft Recall's commercial policies are the benchmark: managed devices default disabled/removed, admins can allow availability, but users must opt in to saving snapshots ([Manage Recall](https://learn.microsoft.com/en-us/windows/client-management/manage-recall)).
- Agent governance: who can create, approve, deploy, schedule, share, and retire agents; what tools/actions each agent can use; mandatory human approval before writes/sends/payments/employment/financial/legal/medical actions.
- Permission-aware execution. Glean emphasizes permissions checked on every request and granular control over agent creation/deployment/actions ([Glean Agent Governance](https://www.glean.com/product/agent-governance)).

### Deployment and Operations

- Signed/notarized macOS package, MDM/Jamf/Intune deployment guide, managed preferences/configuration profile, update channels, release notes, rollback path, fleet health, and permission/TCC preflight documentation.
- Enterprise data options: local-only default, customer-managed storage/export, private cloud or BYOC for optional shared services, region residency for any cloud control plane. Glean already markets single-tenant, customer-cloud, and AMER/EMEA/APAC region deployment ([Glean Security](https://www.glean.com/security)).
- SIEM/SOC integration: export audit events, agent runs, policy changes, failures, sensitive-data drops, STOP events, and admin actions.
- Reliability and cost SLOs: per-agent success rate, step budget, action latency, failure taxonomy, retry policy, model/tool spend, and run-level ROI. Enterprise agent research stresses that accuracy alone is insufficient; reliability, latency, security, policy compliance, and cost must be measured together ([CLEAR framework](https://arxiv.org/abs/2511.14136)).

### Data Governance and Privacy

- Local store encryption, customer-controlled retention, secure deletion, encrypted exports, legal hold controls, employee-visible data browser, and employee self-service deletion/export where policy allows.
- DLP integration and exclusions more sophisticated than substring privacy rules: app allow/deny lists, URL deny lists, window-level sensitivity signals, Purview-like classification, screen-capture protection honoring, and policy-driven "do not save" surfaces. Recall's sensitive information filtering and DLP provider policy are directly relevant comparables ([Manage Recall](https://learn.microsoft.com/en-us/windows/client-management/manage-recall)).
- BYOD and contractor policies: whether Cascade runs, what is stored, where audit lives, and what happens on offboarding.

## The $1B Thesis

### Segment

Start with services and operations-heavy knowledge work where time savings are measurable and repeated workflows are common: consulting/implementation partners, BPO/back-office operations, finance/accounting operations, compliance operations, customer support operations, QA, IT services, RevOps, and legal ops. These teams already quantify time, throughput, SOP adherence, and exceptions. They also suffer from cross-app work that pure API automation misses.

The initial ICP should be 500-10,000 employee service/operations organizations with high software sprawl and a clear employee-enablement buyer: COO, CIO, transformation leader, operations excellence, or services automation leader. Avoid early deployments where the buyer's primary intent is individual productivity surveillance.

### Wedge

The wedge is "private work memory that finds automations from what employees already do." Most agent platforms require someone to define the workflow first. Cascade observes local work context, proves repeated work with rewind evidence, proposes a reviewed automation, then executes through existing UI with a visible STOP/audit trail.

This is a new path from discovery to automation:

1. Capture local work evidence.
2. Detect repeated cross-app actions.
3. Let the employee review and approve.
4. Replay with verification and audit.
5. Measure completed runs and reclaimed time.

### Moat

- **Trust moat:** local-first capture, employee-visible controls, explicit opt-in, audit/export, and non-surveillance positioning.
- **Evidence moat:** a local contribution graph of screen frames, AX/OCR text, input events, citations, and workflow traces that proves why an automation was suggested and what it did.
- **Execution moat:** native macOS computer-use reliability across arbitrary apps plus safer browser sandbox execution for web workflows.
- **Learning moat:** approved skills and agents compound per user/team/org from real work traces rather than generic templates.
- **Governance moat:** if built correctly, Cascade preserves human approval flows by acting through the same UI controls humans use, rather than bypassing them through backend integrations. That aligns with the "emulated human behavior" argument for secure enterprise agents preserving existing controls ([TechRadar](https://www.techradar.com/pro/secure-ai-will-be-defined-by-emulated-human-behavior)).

### Pricing Direction

Use hybrid pricing:

- **Employee memory seat:** per active recorder seat, priced like productivity/security software.
- **Agent operator seat:** higher tier for users who create/deploy/schedule agents.
- **Admin/security seat:** included in enterprise plan for governance roles.
- **Usage meter:** agent-run minutes/actions/model spend above included quota, with hard budgets and department-level chargeback.
- **Enterprise platform fee:** for SSO/SCIM, MDM, SIEM, DLP, custom retention, private cloud/BYOC, legal/compliance support, and SLA.

Avoid pure outcome pricing early. The product touches sensitive workflows and reliability is still probabilistic; buyers will want predictable spend and the ability to cap agent actions. Public reporting on Salesforce suggests large enterprise AI customers pushed back toward predictable per-user licensing after conversation-based pricing experiments ([TechRadar](https://www.techradar.com/pro/salesforce-says-per-user-pricing-will-be-new-ai-norm)).

At $50-$100 per employee/month blended across memory, agent, and enterprise tiers, 1M paid seats implies $600M-$1.2B ARR before overages or services. A more realistic path is to land teams at 500-2,000 seats, expand through departments once privacy controls are trusted, and add agent usage as successful automations scale.

## Concrete Product Gaps to Close

### P0: Enterprise Trust and Control

1. **Org/tenant model, SSO, SCIM, and RBAC**
   - Current mapping: AppShell settings are user-local; CascadeMemory is local; no org tenant/admin layer.
   - Engineering work: add organization identity, user roles, policy sync, group assignment, admin console, license state, and deprovisioning/offboarding wipe/export semantics.

2. **Enterprise policy engine for recording and agents**
   - Current mapping: `PrivacyRules` is a substring exclude-list; power harness is a local Settings toggle; action classes exist conceptually through tool permission classes.
   - Engineering work: policy schema for recording availability, app/site/window exclusions, sensitive-data detection, retention/storage, power tools, connector permissions, approval requirements, scheduled-run rules, and managed-device defaults.

3. **Compliance package and security posture**
   - Current mapping: local audit exists; Keychain storage exists; no external compliance program.
   - Engineering work: SOC 2 readiness, pen test, threat model, secure SDLC, vulnerability disclosure, DPA/subprocessor docs, model data-use commitments, encryption-at-rest review for SQLite/JPEG blobs, key management strategy, and incident response process.

4. **MDM deployment and macOS permission operations**
   - Current mapping: build script produces `.build/Cascade.app`; permissions are user-prompted from Settings.
   - Engineering work: signed/notarized PKG, auto-update channel, Jamf/Intune deployment docs, PPPC/TCC profile guidance for Screen Recording/Accessibility/Input Monitoring where possible, first-run fleet health, and rollback.

5. **Audit export and SIEM integration**
   - Current mapping: `audit_event` is local and visible in limited UI surfaces.
   - Engineering work: tamper-evident local audit chain, export API/CLI, JSON schema, SIEM webhooks, admin-visible event search, run replay package, evidence bundle export, and retention/legal-hold policy.

6. **Employee data rights and privacy UX**
   - Current mapping: Reel and proof chips expose local context; manager analytics are limited.
   - Engineering work: employee "privacy outbox," what-was-captured viewer, per-source deletion/export, policy explanation, recording pause history, consent/notice UX, and aggregate-only manager dashboards by default.

### P1: Production Automation Reliability

7. **Agent eval harness and SLA metrics**
   - Current mapping: tests exist and demo fixtures cover workflows; no enterprise SLO dashboard.
   - Engineering work: deterministic replay fixtures, app-specific eval suites, success/failure taxonomy, step latency, no-effect-loop detection metrics, cost per successful run, and release gates by app/workflow class.

8. **Action simulation, dry-run, and approvals**
   - Current mapping: STOP/audit and some high-risk refusals exist; draft emails stop before sending in demos.
   - Engineering work: dry-run mode, preflight diff/preview, mandatory approval checkpoints, "never send/pay/delete externally" policies, signed approvals, and rollback/undo recipes when possible.

9. **DLP and sensitivity integration**
   - Current mapping: substring drops; no classification provider.
   - Engineering work: app/site allow/deny policy, OCR/AX sensitive classifiers, enterprise DLP provider hooks, window-level sensitivity metadata, per-field redaction/drop decisions, and tests for password/health/finance/HR data.

10. **Connector strategy without losing the local-first wedge**
   - Current mapping: direct-Mac harness and sandbox tools exist; integrations are mostly local/browser/harness.
   - Engineering work: typed MCP/tool catalog with admin permission classes, enterprise connector registry, OAuth/admin consent, least-privilege scopes, credential vaulting, connector audit, and default read-only integrations before writes.

11. **Background execution isolation**
   - Current mapping: WKWebView sandbox with persistent data store; local VM backend is defined but not built.
   - Engineering work: hardened local VM/container boundary for background agents, per-agent secrets/session isolation, screenshot/data leak controls, reset/snapshot lifecycle, and admin policy for which workflows may run unattended.

### P2: Market Packaging and GTM

12. **Enterprise admin product surface**
   - Current mapping: Manager tab is local analytics, not a multi-user admin console.
   - Engineering work: org dashboard for rollout, adoption, policy compliance, risky automations, audit export, agent inventory, ROI, and department-level budget controls.

13. **Workflow library and services-led adoption**
   - Current mapping: learned skills and detected agents are local.
   - Engineering work: reviewed team templates, industry starter packs for services ops/support/finance ops, approval workflow for sharing, and customer-success playbooks for "discover -> review -> deploy -> measure."

14. **Pricing and value instrumentation**
   - Current mapping: reclaimed time math exists locally.
   - Engineering work: seat tiers, usage quotas, run budgets, cost-per-run reporting, ROI dashboards, department chargeback, and "completed run" accounting that finance can trust.

15. **Legal/labor deployment kit**
   - Current mapping: privacy-first product posture exists but no formal buyer collateral.
   - Engineering work: employee FAQ, works-council packet, DPIA template, acceptable-use policy, monitoring-vs-assistance positioning, and manager analytics guardrails.

## Positioning/Risk (Surveillance Backlash)

Cascade should not position as "employee monitoring," "bossware," "AI manager," or "replace employees." That path creates procurement resistance, employee revolt, works-council blockers, and brand damage. The recent Meta tracking backlash is the warning: screen, keystroke, mouse, and prompt capture for AI training can become unacceptable even inside an AI company when employees do not trust access boundaries or purpose limitation ([Guardian](https://www.theguardian.com/technology/2026/jun/24/meta-pauses-employee-tracker-for-ai-training-amid-privacy-concerns), [Wired](https://www.wired.com/story/meta-accidentally-let-employees-access-each-others-keystroke-data)).

Use this positioning instead:

- **Employee-owned work memory:** "Find what you saw, recover context, and prove answers with receipts."
- **Reviewed automation:** "Cascade suggests helpers from repeated work; employees approve before agents exist."
- **Visible, stoppable execution:** "Esc always wins; every action is audited."
- **Manager-safe analytics:** "Managers see aggregate automation opportunity and completed-run value, not raw screens or individual keystroke productivity."
- **Local-first by default:** "Sensitive work context stays on the Mac unless the employee/admin explicitly exports or enables enterprise sync."
- **Automation without system rewrites:** "Cascade acts through existing apps and UI controls, preserving current approval paths and legacy systems."

Hard positioning rules:

- Never sell individual productivity scoring.
- Never expose raw employee screen history to managers by default.
- Never train global models on customer work traces.
- Never run unattended real-screen agents without explicit policy and user-visible controls.
- Never imply headcount reduction as the main ROI. The wedge is reclaimed time, fewer repetitive steps, better auditability, and faster services delivery.

The strongest enterprise story is: **Cascade is the local context and action layer for trusted work automation. It helps employees prove, repeat, and delegate the boring parts of their own work while giving enterprises the controls needed to govern agents safely.**
