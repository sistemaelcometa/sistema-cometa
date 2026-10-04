"use client";

import * as React from "react";
import type { User } from "@supabase/supabase-js";
import { isSupabaseConfigured, supabase } from "@/lib/supabase/client";

type Organization = {
  id: string;
  name: string;
  slug: string;
};

type Membership = {
  organization_id: string;
  organization_name: string;
  role: "owner" | "admin" | "editor" | "viewer";
  member_status: "pending" | "active" | "disabled";
};

type AuthMode = "login" | "register";

export function AuthGate({ children }: { children: React.ReactNode }) {
  const [user, setUser] = React.useState<User | null>(null);
  const [loading, setLoading] = React.useState(true);
  const [mode, setMode] = React.useState<AuthMode>("login");
  const [message, setMessage] = React.useState("");
  const [organization, setOrganization] = React.useState<Organization | null>(
    null,
  );
  const [memberships, setMemberships] = React.useState<Membership[]>([]);
  const activeMembership = memberships.find(
    (membership) => membership.member_status === "active",
  );

  const loadAccessState = React.useCallback(async () => {
    if (!supabase) return;

    const [organizationResponse, membershipsResponse] = await Promise.all([
      supabase.rpc("get_default_organization").maybeSingle(),
      supabase.rpc("get_my_memberships"),
    ]);

    if (organizationResponse.error) {
      setMessage(organizationResponse.error.message);
    } else {
      setOrganization(organizationResponse.data as Organization | null);
    }

    if (membershipsResponse.error) {
      setMessage(membershipsResponse.error.message);
      setMemberships([]);
    } else {
      setMemberships((membershipsResponse.data ?? []) as Membership[]);
    }
  }, []);

  React.useEffect(() => {
    if (!supabase) {
      setLoading(false);
      return;
    }

    let mounted = true;

    supabase.auth.getUser().then(async ({ data }) => {
      if (!mounted) return;
      setUser(data.user);
      if (data.user) await loadAccessState();
      setLoading(false);
    });

    const { data: listener } = supabase.auth.onAuthStateChange(
      async (_event, session) => {
        setUser(session?.user ?? null);
        setMessage("");
        if (session?.user) {
          await loadAccessState();
        } else {
          setMemberships([]);
        }
      },
    );

    return () => {
      mounted = false;
      listener.subscription.unsubscribe();
    };
  }, [loadAccessState]);

  async function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!supabase) return;

    const form = new FormData(event.currentTarget);
    const email = String(form.get("email") ?? "").trim();
    const password = String(form.get("password") ?? "");

    setLoading(true);
    setMessage("");

    const result =
      mode === "login"
        ? await supabase.auth.signInWithPassword({ email, password })
        : await supabase.auth.signUp({ email, password });

    if (result.error) {
      setMessage(result.error.message);
    } else if (mode === "register") {
      setMessage("Usuario creado. Si Supabase pide confirmar email, revisa tu correo.");
    }

    setLoading(false);
  }

  async function handleSignOut() {
    if (!supabase) return;
    await supabase.auth.signOut();
  }

  async function requestAccess(action: "claim" | "request") {
    if (!supabase || !organization) return;

    setLoading(true);
    setMessage("");

    const response =
      action === "claim"
        ? await supabase.rpc("claim_initial_owner", {
            target_organization_id: organization.id,
          })
        : await supabase.rpc("request_organization_access", {
            target_organization_id: organization.id,
          });

    if (response.error) {
      setMessage(response.error.message);
    } else {
      await loadAccessState();
      setMessage(
        action === "claim"
          ? "Rol owner activado."
          : "Solicitud enviada. Un administrador debe habilitar tu usuario.",
      );
    }

    setLoading(false);
  }

  if (!isSupabaseConfigured) {
    return (
      <main className="auth-shell">
        <AuthCard title="Conectar Supabase">
          <p>
            Faltan `NEXT_PUBLIC_SUPABASE_URL` y `NEXT_PUBLIC_SUPABASE_ANON_KEY`
            en el entorno.
          </p>
        </AuthCard>
      </main>
    );
  }

  if (loading && !user) {
    return (
      <main className="auth-shell">
        <AuthCard title="Cargando acceso">
          <p>Validando sesión.</p>
        </AuthCard>
      </main>
    );
  }

  if (!user) {
    return (
      <main className="auth-shell">
        <AuthCard title="El Cometa">
          <form className="auth-form" onSubmit={handleSubmit}>
            <label>
              Email
              <input name="email" type="email" autoComplete="email" required />
            </label>
            <label>
              Contraseña
              <input
                name="password"
                type="password"
                autoComplete={
                  mode === "login" ? "current-password" : "new-password"
                }
                minLength={6}
                required
              />
            </label>
            {message && <p className="auth-message">{message}</p>}
            <button className="primary-button" type="submit" disabled={loading}>
              {mode === "login" ? "Ingresar" : "Crear usuario"}
            </button>
            <button
              className="auth-link-button"
              type="button"
              onClick={() => {
                setMode(mode === "login" ? "register" : "login");
                setMessage("");
              }}
            >
              {mode === "login"
                ? "Crear usuario nuevo"
                : "Ya tengo usuario"}
            </button>
          </form>
        </AuthCard>
      </main>
    );
  }

  if (!activeMembership) {
    const pendingMembership = memberships.find(
      (membership) => membership.member_status === "pending",
    );

    return (
      <main className="auth-shell">
        <AuthCard title="Acceso a El Cometa">
          <p>{user.email}</p>
          {pendingMembership ? (
            <p>Tu usuario está pendiente de aprobación.</p>
          ) : (
            <div className="auth-actions">
              <button
                className="primary-button"
                type="button"
                onClick={() => requestAccess("request")}
                disabled={loading || !organization}
              >
                Solicitar acceso
              </button>
              <button
                className="secondary-button"
                type="button"
                onClick={() => requestAccess("claim")}
                disabled={loading || !organization}
              >
                Soy el primer dueño
              </button>
            </div>
          )}
          {message && <p className="auth-message">{message}</p>}
          <button className="auth-link-button" type="button" onClick={handleSignOut}>
            Salir
          </button>
        </AuthCard>
      </main>
    );
  }

  return (
    <>
      <div className="session-strip">
        <span>
          {user.email} · {activeMembership.role}
        </span>
        <button type="button" onClick={handleSignOut}>
          Salir
        </button>
      </div>
      {children}
    </>
  );
}

function AuthCard({
  title,
  children,
}: {
  title: string;
  children: React.ReactNode;
}) {
  return (
    <section className="auth-card">
      <img src="/el-cometa-logo.png" alt="El Cometa" />
      <h1>{title}</h1>
      {children}
    </section>
  );
}
