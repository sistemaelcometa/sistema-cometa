"use client";

import * as React from "react";
import type { User } from "@supabase/supabase-js";
import {
  isSupabaseConfigured,
  supabase,
  supabaseConfigError,
} from "@/lib/supabase/client";

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

type ManagedMember = {
  member_id: string;
  user_id: string;
  email: string;
  display_name: string | null;
  role: "owner" | "admin" | "editor" | "viewer";
  member_status: "pending" | "active" | "disabled";
  requested_at: string;
  enabled_at: string | null;
};

type AuthMode = "login" | "register";

const ActiveMembershipContext = React.createContext<Membership | null>(null);

export function useActiveMembership() {
  return React.useContext(ActiveMembershipContext);
}

export function AuthGate({ children }: { children: React.ReactNode }) {
  const [user, setUser] = React.useState<User | null>(null);
  const [loading, setLoading] = React.useState(true);
  const [mode, setMode] = React.useState<AuthMode>("login");
  const [message, setMessage] = React.useState("");
  const [showMembers, setShowMembers] = React.useState(false);
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
          <p>{supabaseConfigError}</p>
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
    <ActiveMembershipContext.Provider value={activeMembership}>
      <div className="session-strip">
        <span>
          {user.email} · {activeMembership.role}
        </span>
        {["owner", "admin"].includes(activeMembership.role) && (
          <button type="button" onClick={() => setShowMembers(true)}>
            Usuarios
          </button>
        )}
        <button type="button" onClick={handleSignOut}>
          Salir
        </button>
      </div>
      {showMembers && (
        <MembersModal
          membership={activeMembership}
          onClose={() => setShowMembers(false)}
        />
      )}
      {children}
    </ActiveMembershipContext.Provider>
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

function MembersModal({
  membership,
  onClose,
}: {
  membership: Membership;
  onClose: () => void;
}) {
  const [members, setMembers] = React.useState<ManagedMember[]>([]);
  const [loading, setLoading] = React.useState(true);
  const [message, setMessage] = React.useState("");
  const [disableTarget, setDisableTarget] =
    React.useState<ManagedMember | null>(null);
  const canManageOwners = membership.role === "owner";

  const loadMembers = React.useCallback(async () => {
    if (!supabase) return;

    setLoading(true);
    const response = await supabase.rpc("get_organization_members", {
      target_organization_id: membership.organization_id,
    });

    if (response.error) {
      setMessage(response.error.message);
      setMembers([]);
    } else {
      setMembers((response.data ?? []) as ManagedMember[]);
      setMessage("");
    }

    setLoading(false);
  }, [membership.organization_id]);

  React.useEffect(() => {
    void loadMembers();
  }, [loadMembers]);

  async function enableMember(member: ManagedMember, role: ManagedMember["role"]) {
    if (!supabase) return;

    setLoading(true);
    const response = await supabase.rpc("enable_member", {
      target_organization_id: membership.organization_id,
      target_user_id: member.user_id,
      target_role: role,
    });

    if (response.error) {
      setMessage(response.error.message);
    } else {
      await loadMembers();
      setMessage("Usuario actualizado.");
    }

    setLoading(false);
  }

  async function disableMember() {
    if (!supabase || !disableTarget) return;

    setLoading(true);
    const response = await supabase.rpc("disable_member", {
      target_organization_id: membership.organization_id,
      target_user_id: disableTarget.user_id,
    });

    if (response.error) {
      setMessage(response.error.message);
    } else {
      await loadMembers();
      setMessage("Usuario desactivado.");
      setDisableTarget(null);
    }

    setLoading(false);
  }

  return (
    <div className="modal-backdrop" role="presentation">
      <section aria-modal="true" className="modal wide-modal" role="dialog">
        <div className="section-title">
          <div>
            <p className="eyebrow">{membership.organization_name}</p>
            <h3>Usuarios y accesos</h3>
            <p>Solicitudes, roles y usuarios activos del sistema.</p>
          </div>
          <button
            className="icon-button"
            type="button"
            onClick={onClose}
            aria-label="Cerrar"
          >
            X
          </button>
        </div>
        {message && <p className="auth-message">{message}</p>}
        {loading && members.length === 0 ? (
          <p className="empty-state">Cargando usuarios.</p>
        ) : members.length === 0 ? (
          <p className="empty-state">No hay usuarios para mostrar.</p>
        ) : (
          <div className="responsive-table access-table">
            <table>
              <thead>
                <tr>
                  <th>Usuario</th>
                  <th>Estado</th>
                  <th>Rol</th>
                  <th>Solicitud</th>
                  <th>Acciones</th>
                </tr>
              </thead>
              <tbody>
                {members.map((member) => {
                  const isOwner = member.role === "owner";
                  const canEditMember = canManageOwners || !isOwner;

                  return (
                    <tr key={member.member_id}>
                      <td>
                        <strong>{member.display_name || member.email}</strong>
                        <small>{member.email}</small>
                      </td>
                      <td>
                        <span className={`status-pill ${memberStatusTone(member.member_status)}`}>
                          {memberStatusLabel(member.member_status)}
                        </span>
                      </td>
                      <td>
                        <select
                          value={member.role}
                          disabled={!canEditMember || loading}
                          onChange={(event) =>
                            enableMember(
                              member,
                              event.target.value as ManagedMember["role"],
                            )
                          }
                        >
                          <option value="viewer">Viewer</option>
                          <option value="editor">Editor</option>
                          <option value="admin">Admin</option>
                          {canManageOwners && <option value="owner">Owner</option>}
                        </select>
                      </td>
                      <td>{formatAccessDate(member.requested_at)}</td>
                      <td>
                        <div className="table-actions">
                          {member.member_status !== "active" && (
                            <button
                              className="secondary-button compact-action"
                              type="button"
                              disabled={!canEditMember || loading}
                              onClick={() => enableMember(member, member.role)}
                            >
                              Aprobar
                            </button>
                          )}
                          {member.member_status === "active" && (
                            <button
                              className="secondary-button compact-action danger-soft"
                              type="button"
                              disabled={!canEditMember || loading}
                              onClick={() => setDisableTarget(member)}
                            >
                              Desactivar
                            </button>
                          )}
                        </div>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </section>
      {disableTarget && (
        <div className="modal-backdrop stacked-modal" role="presentation">
          <section aria-modal="true" className="modal" role="dialog">
            <div className="section-title">
              <div>
                <h3>Desactivar usuario</h3>
                <p>{disableTarget.email}</p>
              </div>
              <button
                className="icon-button"
                type="button"
                onClick={() => setDisableTarget(null)}
                aria-label="Cerrar"
              >
                X
              </button>
            </div>
            <p className="warning-box delete-warning-box">
              El usuario no podra ingresar al sistema hasta que vuelva a ser
              habilitado.
            </p>
            <div className="modal-actions">
              <button
                className="secondary-button"
                type="button"
                onClick={() => setDisableTarget(null)}
              >
                Cancelar
              </button>
              <button
                className="primary-button"
                type="button"
                disabled={loading}
                onClick={disableMember}
              >
                Desactivar
              </button>
            </div>
          </section>
        </div>
      )}
    </div>
  );
}

function memberStatusLabel(status: ManagedMember["member_status"]) {
  return {
    pending: "Pendiente",
    active: "Activo",
    disabled: "Desactivado",
  }[status];
}

function memberStatusTone(status: ManagedMember["member_status"]) {
  return {
    pending: "warning",
    active: "success",
    disabled: "danger",
  }[status];
}

function formatAccessDate(value: string) {
  return new Intl.DateTimeFormat("es-AR", {
    day: "2-digit",
    month: "2-digit",
    year: "2-digit",
  }).format(new Date(value));
}
