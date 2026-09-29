# El Cometa Gestion

Sistema administrativo para El Cometa, preparado como aplicacion Next.js para desplegar en Vercel y conectar con Supabase.

## Stack

- Next.js 16
- React 19
- Supabase/Postgres mediante migraciones SQL en `supabase/migrations`
- pnpm como gestor de paquetes

## Requisitos

- Node.js `>=22.13.0`
- pnpm

## Desarrollo Local

```bash
pnpm install
pnpm dev
```

La app queda disponible en `http://localhost:3000`.

## Build

```bash
pnpm build
pnpm test
```

## Variables De Entorno

Copiar `.env.example` a `.env.local` y completar:

```bash
NEXT_PUBLIC_SUPABASE_URL=
NEXT_PUBLIC_SUPABASE_ANON_KEY=
SUPABASE_SERVICE_ROLE_KEY=
```

## Supabase

La migracion inicial esta en:

```text
supabase/migrations/001_initial_rentals_schema.sql
```

La pantalla actual todavia funciona con estado local limpio. La conexion real a Supabase queda lista para implementarse sobre esta estructura.

## Despliegue En Vercel

1. Subir el proyecto a GitHub.
2. Importar el repositorio en Vercel.
3. Configurar las variables de entorno de Supabase.
4. Usar `pnpm build` como comando de build.
