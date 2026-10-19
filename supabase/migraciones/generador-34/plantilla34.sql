-- OpsFlow · 34 · Asignación solo por el líder de cada departamento + sustituciones temporales
-- OPS-GLOBAL-AUD-001 / G-MST-001, G-MST-002: Cleaning Leader asigna cleaners; Drivers Leader asigna drivers.
--   Operación consulta y coordina, pero NO asigna ni suelta asignaciones (ni en la app ni en el servidor).
-- OPS-ADM-001 / G-MST-003: Operación nombra un sustituto temporal (con fechas) cuando falta un líder.
--   El sustituto es un operador ACTIVO del mismo departamento. Entre "desde" y "hasta" SUMA las facultades
--   del líder de SU departamento (asignar, ver lo que ve el líder, recibir sus avisos) y CONSERVA su trabajo
--   de operador (un driver sigue escaneando bolsas; un cleaner sigue con su "Mi día"). Su nivel no cambia.
--
-- Errores con código: 42501 = sin permiso · 22023 = dato no válido · 23P01 = sustituciones que se solapan.
--
-- Ejecutar DESPUÉS de 00-MONTAR (proyecto de pruebas) o de 33-PEGAR-horario.sql.
-- SOLO en el proyecto de PRUEBAS. Para producción hace falta autorización expresa y una marca de entorno propia.
-- Después, ejecutar 35-PEGAR-pruebas_permisos.sql: todas las filas deben decir OK.

-- ✏️ ESCRIBE AQUÍ el identificador del proyecto de PRUEBAS (20 letras; sale en la dirección:
--    supabase.com/dashboard/project/<identificador>). Si no coincide con la marca del proyecto, no se cambia nada.
select set_config('opsflow.proyecto', 'ESCRIBE-AQUI-EL-ID-DEL-PROYECTO', false);

begin;

-- Freno de seguridad: el identificador escrito tiene que coincidir con la marca "pruebas" que dejó 00-MONTAR.
-- Producción no tiene esa marca → se para sin cambiar nada.
do $$
declare v text := current_setting('opsflow.proyecto', true); v_tipo text; v_proy text;
begin
  if v is null or v !~ '^[a-z]{20}$' then
    raise exception 'PARADO: escribe en la primera línea el identificador del proyecto de pruebas (20 letras minúsculas). No se ha cambiado nada.';
  end if;
  if v = 'zxsiantglodsqqvigndk' then
    raise exception 'PARADO: ese identificador es el de PRODUCCIÓN. No se ha cambiado nada.';
  end if;
  if to_regclass('public.opsflow_entorno') is not null then
    execute 'select tipo, proyecto from public.opsflow_entorno where id = 1' into v_tipo, v_proy;
  end if;
  if v_tipo is distinct from 'pruebas' then
    raise exception 'PARADO: esta base de datos no tiene la marca de entorno de PRUEBAS (la crea 00-MONTAR). No se ha cambiado nada.';
  end if;
  if v_proy <> v then
    raise exception 'PARADO: escribiste % pero este proyecto está marcado como %. No se ha cambiado nada.', v, v_proy;
  end if;
  if exists (select 1 from public.propiedades where not es_prueba) then
    raise exception 'PARADO: hay propiedades reales en esta base de datos. No se ha cambiado nada.';
  end if;
end $$;

-- 1. Sustituciones --------------------------------------------------------------------------
create extension if not exists btree_gist with schema extensions;

create table if not exists public.sustituciones (
  id            uuid primary key default gen_random_uuid(),
  departamento  text not null check (departamento in ('Limpieza', 'Linens', 'Drivers')),
  sustituto     uuid not null references public.perfiles(id),
  desde         timestamptz not null,
  hasta         timestamptz not null,
  motivo        text not null check (length(btrim(motivo)) between 3 and 200),
  nombrado_por  uuid not null references public.perfiles(id),
  nombrado_en   timestamptz not null default now(),
  revocada_por  uuid references public.perfiles(id),
  revocada_en   timestamptz,
  check (hasta > desde)
);
create index if not exists sustituciones_sustituto on public.sustituciones (sustituto, desde, hasta) where revocada_en is null;
-- La base de datos misma impide dos sustituciones activas del mismo departamento con fechas solapadas,
-- aunque lleguen dos peticiones a la vez (G-MST-010).
alter table public.sustituciones drop constraint if exists sustituciones_sin_solape;
alter table public.sustituciones add constraint sustituciones_sin_solape
  exclude using gist (departamento with =, tstzrange(desde, hasta) with &&) where (revocada_en is null);

alter table public.sustituciones enable row level security;
-- Desde el navegador no se lee ni se escribe nunca: solo con las funciones de abajo
revoke all on public.sustituciones from anon, authenticated;

-- 2. ¿Quién es líder de un departamento? -----------------------------------------------------
-- mi_nivel() vuelve a ser exactamente la de 001_cuentas.sql: el sustituto sigue siendo "operador".
create or replace function public.mi_nivel()
returns public.nivel
language sql stable security definer set search_path = ''
as $$
  select nivel from public.perfiles where id = (select auth.uid()) and activo
$$;
revoke execute on function public.mi_nivel() from public, anon;
grant  execute on function public.mi_nivel() to authenticated;

-- Una persona es líder de p_dep si es su líder real, o un operador de ESE departamento con sustitución vigente.
create or replace function public._es_lider_id(p_id uuid, p_dep text)
returns boolean language sql stable security definer set search_path = ''
as $$
  select coalesce((
    select p.activo and p.departamento = p_dep
           and (p.nivel = 'lider'
                or (p.nivel = 'operador' and exists (
                      select 1 from public.sustituciones s
                       where s.sustituto = p.id and s.departamento = p_dep
                         and s.revocada_en is null and now() >= s.desde and now() < s.hasta)))
      from public.perfiles p where p.id = p_id), false)
$$;
revoke execute on function public._es_lider_id(uuid, text) from public, anon, authenticated;

-- Para quien llama (se usa también en las reglas de lectura RLS, por eso authenticated puede ejecutarla)
create or replace function public._es_lider(p_dep text)
returns boolean language sql stable security definer set search_path = ''
as $$ select public._es_lider_id((select auth.uid()), p_dep) $$;
revoke execute on function public._es_lider(text) from public, anon;
grant  execute on function public._es_lider(text) to authenticated;

create or replace function public._es_lider_en(p_deps text[])
returns boolean language sql stable security definer set search_path = ''
as $$ select coalesce(public.mi_departamento() = any(p_deps) and public._es_lider(public.mi_departamento()), false) $$;
revoke execute on function public._es_lider_en(text[]) from public, anon;
grant  execute on function public._es_lider_en(text[]) to authenticated;

create or replace function public._soy_sustituto()
returns boolean language sql stable security definer set search_path = ''
as $$ select public.mi_nivel() = 'operador' and public._es_lider(public.mi_departamento()) $$;
revoke execute on function public._soy_sustituto() from public, anon;
grant  execute on function public._soy_sustituto() to authenticated;

-- ¿Quien llama puede ASIGNAR personal de p_dep? Su líder o su sustituto vigente. Operación NO.
create or replace function public._asigna(p_dep text)
returns boolean language sql stable security definer set search_path = ''
as $$ select public._es_lider(p_dep) $$;
revoke execute on function public._asigna(text) from public, anon, authenticated;

-- Consultas y gestiones de Limpieza que NO son asignar personal (cancelar, reabrir, ver tiempos…):
-- Operación las conserva; el líder de Limpieza o su sustituto también.
create or replace function public._lider_limpieza()
returns boolean language sql stable security definer set search_path = ''
as $$ select public.mi_nivel() = 'operacion' or public._es_lider('Limpieza') $$;
revoke execute on function public._lider_limpieza() from public, anon, authenticated;

-- 3. Asignaciones de Limpieza y de Drivers: solo su líder (mismo cuerpo que 30 / 04 / 27 / 21) ----------
@@ASIGNAR@@
-- 4. Soltar una tarea de driver ------------------------------------------------------------------
--   · la tarea que el driver cogió él mismo del tablero: la puede soltar él
--   · la tarea que ASIGNÓ el líder: solo el líder de Drivers (o su sustituto); el driver usa "No pude entregar"
--   · Operación ya no suelta tareas de nadie
create or replace function public.soltar_tarea(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.pendientes;
begin
  select * into v from public.pendientes where id = p_id for update;
  if not found then raise exception using errcode = '22023', message = 'Ese pendiente no existe.'; end if;
  if not public._es_lider('Drivers') then
    if v.tomado_por is distinct from (select auth.uid()) then
      raise exception using errcode = '42501', message = 'Solo el driver que la cogió o el líder de drivers (o su sustituto) la sueltan.';
    end if;
    if v.asignado_por is not null then
      raise exception using errcode = '42501', message = 'Esta tarea la asignó el líder: usa "No pude entregar" o pide al líder que la suelte.';
    end if;
  end if;
  update public.pendientes set tomado_por = null, tomado_en = null, asignado_por = null where id = p_id;
  perform public._evento('tarea soltada', v.limpieza_id, p_id);
end $$;

-- 5. Funciones y reglas de lectura donde "líder de X" pasa a incluir al sustituto vigente de X --------
--    (generado automáticamente a partir del backend 1–33; solo cambia esa comprobación)
@@GENERADO_FUNCIONES@@
@@GENERADO_POLITICAS@@
-- 6. Nombrar / revocar / consultar sustituciones (solo Operación escribe) ---------------------
create or replace function public.nombrar_sustituto(p_departamento text, p_sustituto uuid,
                                                    p_desde timestamptz, p_hasta timestamptz, p_motivo text)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare v_id uuid; v_nom text;
begin
  if public.mi_nivel() is distinct from 'operacion' then
    raise exception using errcode = '42501', message = 'Solo Operación nombra sustitutos.';
  end if;
  if p_departamento is null or p_departamento not in ('Limpieza', 'Linens', 'Drivers') then
    raise exception using errcode = '22023', message = 'Departamento no válido.';
  end if;
  select nombre into v_nom from public.perfiles
   where id = p_sustituto and activo and departamento = p_departamento and nivel = 'operador';
  if v_nom is null then
    raise exception using errcode = '22023', message = format('El sustituto tiene que ser un operador activo de %s.', p_departamento);
  end if;
  if p_desde is null or p_hasta is null or p_hasta <= p_desde then
    raise exception using errcode = '22023', message = 'La fecha "hasta" tiene que ser posterior a "desde".';
  end if;
  if p_hasta <= now() then raise exception using errcode = '22023', message = 'Esa sustitución ya habría terminado.'; end if;
  if length(btrim(coalesce(p_motivo, ''))) < 3 then raise exception using errcode = '22023', message = 'Escribe el motivo.'; end if;
  -- Una petición a la vez por departamento (la segunda espera y ve la primera). Aunque fallara esto,
  -- la restricción sustituciones_sin_solape de la tabla impide igualmente el solape.
  perform pg_advisory_xact_lock(hashtext('opsflow.sustituciones.' || p_departamento));
  if exists (select 1 from public.sustituciones
              where departamento = p_departamento and revocada_en is null
                and desde < p_hasta and p_desde < hasta) then
    raise exception using errcode = '23P01', message = format('Ya hay un sustituto de %s en esas fechas. Revócalo primero.', p_departamento);
  end if;
  begin
    insert into public.sustituciones (departamento, sustituto, desde, hasta, motivo, nombrado_por)
    values (p_departamento, p_sustituto, p_desde, p_hasta, left(btrim(p_motivo), 200), (select auth.uid()))
    returning id into v_id;
  exception when exclusion_violation then
    raise exception using errcode = '23P01', message = format('Ya hay un sustituto de %s en esas fechas. Revócalo primero.', p_departamento);
  end;
  insert into public.eventos (quien, que) values ((select auth.uid()),
    'sustituto de ' || p_departamento || ': ' || v_nom || ' · ' ||
    to_char(p_desde at time zone 'Europe/Malta', 'DD/MM HH24:MI') || ' → ' || to_char(p_hasta at time zone 'Europe/Malta', 'DD/MM HH24:MI'));
  return v_id;
end $$;
revoke execute on function public.nombrar_sustituto(text, uuid, timestamptz, timestamptz, text) from public, anon;
grant  execute on function public.nombrar_sustituto(text, uuid, timestamptz, timestamptz, text) to authenticated;

create or replace function public.revocar_sustitucion(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.sustituciones;
begin
  if public.mi_nivel() is distinct from 'operacion' then
    raise exception using errcode = '42501', message = 'Solo Operación revoca sustitutos.';
  end if;
  select * into v from public.sustituciones where id = p_id for update;
  if not found then raise exception using errcode = '22023', message = 'Esa sustitución no existe.'; end if;
  if v.revocada_en is not null then raise exception using errcode = '22023', message = 'Esa sustitución ya estaba revocada.'; end if;
  if v.hasta <= now() then raise exception using errcode = '22023', message = 'Esa sustitución ya terminó.'; end if;
  update public.sustituciones set revocada_en = now(), revocada_por = (select auth.uid()) where id = p_id;
  insert into public.eventos (quien, que) values ((select auth.uid()),
    'sustitución revocada: ' || v.departamento || ' · ' || (select nombre from public.perfiles where id = v.sustituto));
end $$;
revoke execute on function public.revocar_sustitucion(uuid) from public, anon;
grant  execute on function public.revocar_sustitucion(uuid) to authenticated;

-- Lista para Operación: vigentes, programadas y las de los últimos 30 días
create or replace function public.sustituciones_lista()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
begin
  if public.mi_nivel() is distinct from 'operacion' then
    raise exception using errcode = '42501', message = 'Solo Operación.';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', s.id, 'departamento', s.departamento, 'sustituto', p.nombre, 'desde', s.desde, 'hasta', s.hasta,
      'motivo', s.motivo, 'nombrado_por', n.nombre,
      'estado', case when s.revocada_en is not null then 'revocada' when s.hasta <= now() then 'terminada'
                     when s.desde > now() then 'programada' else 'vigente' end)
      order by s.desde desc)
    from public.sustituciones s join public.perfiles p on p.id = s.sustituto join public.perfiles n on n.id = s.nombrado_por
   where s.hasta > now() - interval '30 days'), '[]'::jsonb);
end $$;
revoke execute on function public.sustituciones_lista() from public, anon;
grant  execute on function public.sustituciones_lista() to authenticated;

-- Para la app: ¿soy sustituto ahora mismo? (null si no)
create or replace function public.mi_sustitucion()
returns jsonb language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object('departamento', s.departamento, 'hasta', s.hasta)
    from public.sustituciones s join public.perfiles p on p.id = s.sustituto
   where s.sustituto = (select auth.uid()) and p.activo and p.nivel = 'operador' and p.departamento = s.departamento
     and s.revocada_en is null and now() >= s.desde and now() < s.hasta
   order by s.hasta desc limit 1
$$;
revoke execute on function public.mi_sustitucion() from public, anon;
grant  execute on function public.mi_sustitucion() to authenticated;

commit;
