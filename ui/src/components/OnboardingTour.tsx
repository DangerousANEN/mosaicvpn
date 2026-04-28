/**
 * OnboardingTour — four-step guided walk-through shown on the first
 * launch only (gated by `mosaic.v1.onboarded` in localStorage).
 * Walks the user through importing a subscription, probing it, and
 * connecting to the first station. The user can skip or finish at
 * any step; either way the tour gets marked done so it never re-
 * appears.
 *
 * Designed as a stack of static cards centred on the screen, not as
 * spotlight-style anchored coachmarks — that keeps it independent of
 * the underlying screen layout and avoids fragile DOM selectors.
 */

import { useState } from "react";
import { markOnboarded } from "../utils/localStore";

interface OnboardingTourProps {
  onClose: () => void;
}

const STEPS = [
  {
    title: "Welcome to Mosaic",
    body: "A gazetteer-styled VPN client. Subscriptions go in, every station gets pinned on the world map, and Connect opens a local SOCKS / HTTP proxy you can plug into your browser.",
    cta: "Next",
  },
  {
    title: "1 · Add a subscription",
    body: "Open the Pool tab and paste a sing-box / Clash / v2ray / SIP008 URL. Mosaic auto-detects the format and stores the servers. You can also drag & drop a .json / .yaml / .txt file straight onto the window.",
    cta: "Next",
  },
  {
    title: "2 · Probe the stations",
    body: "Click Test all on the subscription card to TCP-probe every server. Verify (URL test) actually fetches a 204 endpoint through each proxy so you can tell which servers really work, not just which ones answer on TCP.",
    cta: "Next",
  },
  {
    title: "3 · Connect",
    body: "Click any pin on the world map, or the row in the Routing register, or just press Space on the Atlas screen for one-click connect to the last station you used. Press Ctrl+F at any time to search the entire roster.",
    cta: "Got it",
  },
];

export function OnboardingTour({ onClose }: OnboardingTourProps): JSX.Element {
  const [step, setStep] = useState(0);
  const finish = () => {
    markOnboarded();
    onClose();
  };
  const cur = STEPS[step];
  const last = step === STEPS.length - 1;
  return (
    <div className="onboarding-scrim" onClick={finish}>
      <div className="onboarding-card" onClick={(e) => e.stopPropagation()}>
        <div className="onboarding-eyebrow mono">
          step {step + 1} of {STEPS.length}
        </div>
        <div className="onboarding-title">{cur.title}</div>
        <div className="onboarding-body">{cur.body}</div>
        <div className="onboarding-actions">
          <button className="btn ghost" onClick={finish}>
            Skip tour
          </button>
          <button
            className="btn primary"
            onClick={() => {
              if (last) finish();
              else setStep((s) => s + 1);
            }}
          >
            {cur.cta}
          </button>
        </div>
        <div className="onboarding-dots">
          {STEPS.map((_, i) => (
            <span
              key={i}
              className={`onboarding-dot ${i === step ? "cur" : ""}`}
            />
          ))}
        </div>
      </div>
    </div>
  );
}
