import { useEffect, useState, type FormEvent } from "react";
import { api } from "../api/client";
import type { Profile, Server, DNSConfig } from "../api/types";

/**
 * ProfileEditor — modal drawer for creating or editing VPN profiles.
 *
 * Props:
 *   profile?   — when provided, edit mode (pre-fill fields)
 *   onClose    — close the drawer
 *   onSaved    — refresh callback after a successful save
 *
 * Fields: name, icon, color, server (dropdown), tunnel_mode, kill_switch,
 * allow_lan, auto_connect, DNS config (mode + proxied/direct upstreams).
 */
export function ProfileEditor({
  profile,
  onClose,
  onSaved,
}: {
  profile?: Profile;
  onClose: () => void;
  onSaved: () => void;
}): JSX.Element {
  const [name, setName] = useState(profile?.name ?? "");
  const [icon, setIcon] = useState(profile?.icon ?? "🌐");
  const [color, setColor] = useState(profile?.color ?? "#c47");
  const [serverId, setServerId] = useState(profile?.server_id ?? "");
  const [tunnelMode, setTunnelMode] = useState(profile?.tunnel_mode ?? "tun");
  const [killSwitch, setKillSwitch] = useState(profile?.kill_switch ?? false);
  const [allowLan, setAllowLan] = useState(profile?.allow_lan ?? false);
  const [autoConnect, setAutoConnect] = useState(profile?.auto_connect ?? false);
  const [dnsMode, setDnsMode] = useState<DNSConfig["mode"]>(
    profile?.dns?.mode ?? "fake-ip",
  );
  const [dnsProxied, setDnsProxied] = useState(profile?.dns?.proxied ?? "https://1.1.1.1/dns-query");
  const [dnsDirect, setDnsDirect] = useState(profile?.dns?.direct ?? "https://223.5.5.5/dns-query");

  const [servers, setServers] = useState<Server[]>([]);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    api.listServers().then(setServers).catch(() => {});
  }, []);

  const onSubmit = async (e: FormEvent) => {
    e.preventDefault();
    if (!name.trim()) return;
    setBusy(true);
    setErr(null);
    const body: Partial<Profile> = {
      name: name.trim(),
      icon,
      color,
      server_id: serverId || undefined,
      tunnel_mode: tunnelMode,
      kill_switch: killSwitch,
      allow_lan: allowLan,
      auto_connect: autoConnect,
      dns: {
        mode: dnsMode,
        proxied: dnsProxied,
        direct: dnsDirect,
      } as DNSConfig,
    };
    try {
      if (profile) {
        await api.updateProfile(profile.id, body);
      } else {
        await api.createProfile(body);
      }
      onSaved();
      onClose();
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div
      style={{
        position: "fixed",
        top: 0,
        right: 0,
        width: 420,
        height: "100%",
        background: "var(--bg, #1a1a1f)",
        borderLeft: "1px solid var(--rule, rgba(255,255,255,0.08))",
        zIndex: 100,
        overflowY: "auto",
        padding: "24px 28px",
      }}
    >
      <div
        style={{
          display: "flex",
          alignItems: "center",
          marginBottom: 24,
        }}
      >
        <h3 style={{ margin: 0, fontSize: 14, letterSpacing: "0.15em", textTransform: "uppercase" }}>
          {profile ? "Edit Profile" : "New Profile"}
        </h3>
        <div style={{ flex: 1 }} />
        <button
          onClick={onClose}
          style={{
            background: "none",
            border: "none",
            color: "var(--ink-mute, #888)",
            cursor: "pointer",
            fontSize: 18,
          }}
        >
          ✕
        </button>
      </div>

      <form onSubmit={onSubmit} style={{ display: "flex", flexDirection: "column", gap: 16 }}>
        <Field label="Name">
          <input
            className="text-input"
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="My Profile"
            style={inputStyle}
          />
        </Field>

        <div style={{ display: "flex", gap: 12 }}>
          <Field label="Icon">
            <input
              className="text-input"
              value={icon}
              onChange={(e) => setIcon(e.target.value)}
              style={{ ...inputStyle, width: 60, textAlign: "center" }}
            />
          </Field>
          <Field label="Color">
            <input
              type="color"
              value={color}
              onChange={(e) => setColor(e.target.value)}
              style={{
                width: 48,
                height: 32,
                border: "none",
                background: "none",
                cursor: "pointer",
              }}
            />
          </Field>
        </div>

        <Field label="Server">
          <select
            className="text-input"
            value={serverId}
            onChange={(e) => setServerId(e.target.value)}
            style={inputStyle}
          >
            <option value="">— None —</option>
            {servers.map((s) => (
              <option key={s.id} value={s.id}>
                {s.name} ({s.protocol})
              </option>
            ))}
          </select>
        </Field>

        <Field label="Tunnel Mode">
          <select
            className="text-input"
            value={tunnelMode}
            onChange={(e) => setTunnelMode(e.target.value)}
            style={inputStyle}
          >
            <option value="tun">TUN (system-wide)</option>
            <option value="proxy">Proxy (SOCKS/HTTP only)</option>
          </select>
        </Field>

        <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
          <Toggle
            label="Kill Switch"
            desc="Block all traffic when VPN drops"
            checked={killSwitch}
            onChange={setKillSwitch}
          />
          <Toggle
            label="Allow LAN"
            desc="Bypass LAN traffic through tunnel"
            checked={allowLan}
            onChange={setAllowLan}
          />
          <Toggle
            label="Auto Connect"
            desc="Connect on app launch"
            checked={autoConnect}
            onChange={setAutoConnect}
          />
        </div>

        <div style={{ borderTop: "1px solid var(--rule)", paddingTop: 16 }}>
          <div
            style={{
              fontSize: 10,
              letterSpacing: "0.18em",
              textTransform: "uppercase",
              color: "var(--ink-mute, #888)",
              marginBottom: 12,
            }}
          >
            DNS Configuration
          </div>
          <Field label="Mode">
            <select
              className="text-input"
              value={dnsMode}
              onChange={(e) =>
                setDnsMode(e.target.value as DNSConfig["mode"])
              }
              style={inputStyle}
            >
              <option value="fake-ip">Fake IP</option>
              <option value="real-ip">Real IP</option>
              <option value="disabled">Disabled</option>
            </select>
          </Field>
          {dnsMode !== "disabled" ? (
            <>
              <Field label="Proxied upstream">
                <input
                  className="text-input"
                  value={dnsProxied}
                  onChange={(e) => setDnsProxied(e.target.value)}
                  placeholder="https://1.1.1.1/dns-query"
                  style={inputStyle}
                />
              </Field>
              <Field label="Direct upstream">
                <input
                  className="text-input"
                  value={dnsDirect}
                  onChange={(e) => setDnsDirect(e.target.value)}
                  placeholder="https://223.5.5.5/dns-query"
                  style={inputStyle}
                />
              </Field>
            </>
          ) : null}
        </div>

        {err ? (
          <div style={{ color: "#f66", fontSize: 12 }}>⚠ {err}</div>
        ) : null}

        <div style={{ display: "flex", gap: 12, marginTop: 8 }}>
          <button
            type="submit"
            disabled={busy || !name.trim()}
            style={btnPrimary}
          >
            {busy ? "Saving…" : profile ? "Update" : "Create"}
          </button>
          <button type="button" onClick={onClose} style={btnSecondary}>
            Cancel
          </button>
        </div>
      </form>
    </div>
  );
}

function Field({
  label,
  children,
}: {
  label: string;
  children: React.ReactNode;
}): JSX.Element {
  return (
    <label style={{ display: "flex", flexDirection: "column", gap: 4 }}>
      <span
        style={{
          fontSize: 10,
          letterSpacing: "0.15em",
          textTransform: "uppercase",
          color: "var(--ink-mute, #888)",
        }}
      >
        {label}
      </span>
      {children}
    </label>
  );
}

function Toggle({
  label,
  desc,
  checked,
  onChange,
}: {
  label: string;
  desc: string;
  checked: boolean;
  onChange: (v: boolean) => void;
}): JSX.Element {
  return (
    <label
      style={{
        display: "flex",
        alignItems: "center",
        gap: 10,
        cursor: "pointer",
        userSelect: "none",
      }}
    >
      <input
        type="checkbox"
        checked={checked}
        onChange={(e) => onChange(e.target.checked)}
        style={{ accentColor: "var(--accent, #c47)" }}
      />
      <div style={{ flex: 1 }}>
        <div style={{ fontSize: 12 }}>{label}</div>
        <div style={{ fontSize: 10, color: "var(--ink-mute, #888)" }}>{desc}</div>
      </div>
    </label>
  );
}

const inputStyle: React.CSSProperties = {
  width: "100%",
  padding: "6px 8px",
  background: "rgba(255,255,255,0.04)",
  border: "1px solid var(--rule, rgba(255,255,255,0.08))",
  borderRadius: 4,
  color: "inherit",
  fontSize: 12,
};

const btnPrimary: React.CSSProperties = {
  flex: 1,
  padding: "8px 16px",
  background: "var(--accent, #c47)",
  border: "none",
  borderRadius: 4,
  color: "#fff",
  fontSize: 12,
  cursor: "pointer",
};

const btnSecondary: React.CSSProperties = {
  padding: "8px 16px",
  background: "none",
  border: "1px solid var(--rule, rgba(255,255,255,0.08))",
  borderRadius: 4,
  color: "var(--ink-mute, #888)",
  fontSize: 12,
  cursor: "pointer",
};
