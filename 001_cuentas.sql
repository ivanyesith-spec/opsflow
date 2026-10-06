-- OpsFlow · modulo cuentas · 001
-- Tabla de perfiles y reglas de acceso (RLS).
-- Se ejecuta UNA vez en Supabase → SQL Editor → pegar todo → Run.

-- 1. Tipos ---------------------------------------------------------------
create type public.nivel as enum ('operador', 'lider', 'operacion');
create type public.zona  as enum ('Norte', 'Centro', 'Sur');

-- 2. Tabla ---------------------------------------------------------------
create table public.perfiles (
  id                 uuid primary key references auth.users(id),
  nombre             text not null,
  departamento       text not null check (departamento in ('Limpieza', 'Linens', 'Drivers', 'Operación')),
  nivel              public.nivel not null default 'operador',
  zona               public.zona,                       -- null = todas
  idioma             text not null default 'en' check (idioma in ('en', 'es')),
  activo             boolean not null default true,
  debe_cambiar_clave boolean not null default true,
  creado_por         uuid references public.perfiles(id),
  creado_en          timestamptz not null default now(),
  desactivado_en     timestamptz
);

alter table public.perfiles enable row level security;

-- Desde el navegador solo se puede LEER. Crear, cambiar o desactivar
-- se hace unicamente desde las funciones del servidor.
revoke insert, update, delete, truncate on public.perfiles from anon, authenticated;
revoke all on public.perfiles from anon;

-- 3. Ayudantes (leen el perfil de quien esta conectado) ------------------
create or replace function public.mi_nivel()
returns public.nivel
language sql stable security definer set search_path = ''
as $$
  select nivel from public.perfiles where id = (select auth.uid()) and activo
$$;

create or replace function public.mi_departamento()
returns text
language sql stable security definer set search_path = ''
as $$
  select departamento from public.perfiles where id = (select auth.uid()) and activo
$$;

revoke execute on function public.mi_nivel(), public.mi_departamento() from public, anon;
grant  execute on function public.mi_nivel(), public.mi_departamento() to authenticated;

-- 4. Regla de lectura ----------------------------------------------------
--   operador  → solo su perfil
--   lider     → su departamento
--   operacion → todos
create policy "perfiles: lectura por nivel"
on public.perfiles for select to authenticated
using (
  id = (select auth.uid())
  or ((select public.mi_nivel()) = 'lider' and departamento = (select public.mi_departamento()))
  or (select public.mi_nivel()) = 'operacion'
);

-- 5. Unica escritura permitida desde la app: marcar que ya cambie mi clave
create or replace function public.clave_cambiada()
returns void
language sql security definer set search_path = ''
as $$
  update public.perfiles set debe_cambiar_clave = false where id = (select auth.uid())
$$;

revoke execute on function public.clave_cambiada() from public, anon;
grant  execute on function public.clave_cambiada() to authenticated;
