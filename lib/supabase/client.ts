"use client";

import { createClient } from "@supabase/supabase-js";

const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
const supabaseAnonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

function isHttpUrl(value: string | undefined) {
  if (!value) return false;

  try {
    const url = new URL(value);
    return url.protocol === "http:" || url.protocol === "https:";
  } catch {
    return false;
  }
}

export const supabaseConfigError = !supabaseUrl
  ? "Falta NEXT_PUBLIC_SUPABASE_URL en el entorno."
  : !isHttpUrl(supabaseUrl)
    ? "NEXT_PUBLIC_SUPABASE_URL debe ser una URL valida, por ejemplo https://bolfcovqkrsogdtiuxwp.supabase.co."
    : !supabaseAnonKey
      ? "Falta NEXT_PUBLIC_SUPABASE_ANON_KEY en el entorno."
      : "";

export const isSupabaseConfigured = !supabaseConfigError;

export const supabase = isSupabaseConfigured
  ? createClient(supabaseUrl!, supabaseAnonKey!, {
      auth: {
        persistSession: true,
        autoRefreshToken: true,
        detectSessionInUrl: true,
      },
    })
  : null;
