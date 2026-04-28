/**
 * ErrorBoundary surfaces unhandled render exceptions inline instead of
 * leaving a blank webview. In a release build without devtools the user
 * has no way to see the stack trace otherwise; in dev/with devtools
 * they still get the console output and can drill in further.
 */

import { Component, type ErrorInfo, type ReactNode } from "react";

interface State {
  error: Error | null;
  info: ErrorInfo | null;
}

interface Props {
  children: ReactNode;
}

export class ErrorBoundary extends Component<Props, State> {
  state: State = { error: null, info: null };

  static getDerivedStateFromError(error: Error): State {
    return { error, info: null };
  }

  componentDidCatch(error: Error, info: ErrorInfo): void {
    // Surface to console for devtools / log capture.
    console.error("ErrorBoundary caught:", error, info);
    this.setState({ error, info });
  }

  render(): ReactNode {
    const { error, info } = this.state;
    if (!error) return this.props.children;
    return (
      <div
        style={{
          padding: 24,
          fontFamily: "ui-monospace, Menlo, Consolas, monospace",
          fontSize: 12,
          lineHeight: 1.5,
          color: "#fda4af",
          background: "#1f1d1b",
          minHeight: "100vh",
          whiteSpace: "pre-wrap",
          overflow: "auto",
        }}
      >
        <h2 style={{ color: "#fecaca", margin: "0 0 12px" }}>
          Mosaic UI crashed
        </h2>
        <div style={{ color: "#fcd34d", marginBottom: 12 }}>
          {error.name}: {error.message}
        </div>
        <details open>
          <summary style={{ cursor: "pointer", color: "#94a3b8" }}>
            stack
          </summary>
          {error.stack ?? "(no stack)"}
        </details>
        {info?.componentStack ? (
          <details open style={{ marginTop: 12 }}>
            <summary style={{ cursor: "pointer", color: "#94a3b8" }}>
              component stack
            </summary>
            {info.componentStack}
          </details>
        ) : null}
      </div>
    );
  }
}
