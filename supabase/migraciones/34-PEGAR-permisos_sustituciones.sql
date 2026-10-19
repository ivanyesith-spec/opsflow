-- OpsFlow · 34 · Asignación solo por el líder de cada departamento + sustituciones temporales
-- OPS-GLOBAL-AUD-001 / G-MST-001, G-MST-002: Cleaning Leader asigna cleaners; Drivers Leader asigna drivers.
--   Operación consulta y coordina, pero ya NO asigna (ni en la app ni en el servidor).
-- OPS-ADM-001 / G-MST-003: Operación nombra un sustituto temporal (con fechas) cuando falta un líder.
--   El sustituto es un operador ACTIVO del mismo departamento y, solo entre "desde" y "hasta",
--   actúa como líder de ese departamento. Nada más cambia de nivel.
--
-- Ejecutar DESPUÉS de 33-PEGAR-horario.sql. Supabase → SQL Editor → pegar todo → Run.
-- PRIMERO en el proyecto de PRUEBAS. NO pegar en producción sin autorización expresa.
-- Después, ejecutar 35-PEGAR-pruebas_permisos.sql: todas las filas deben decir OK.

-- 1. Sustituciones --------------------------------------------------------------------------
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

alter table public.sustituciones enable row level security;
-- Desde el navegador no se escribe nunca: solo con nombrar_sustituto / revocar_sustitucion
revoke all on public.sustituciones from anon, authenticated;

-- 2. Nivel efectivo: el sustituto vigente es "lider" de SU departamento mientras dure --------
--    (mi_departamento() no cambia: un sustituto nunca actúa sobre otro departamento)
create or replace function public.mi_nivel()
returns public.nivel
language sql stable security definer set search_path = ''
as $$
  select case
           when p.nivel = 'operador' and exists (
             select 1 from public.sustituciones s
              where s.sustituto = p.id and s.departamento = p.departamento
                and s.revocada_en is null and now() >= s.desde and now() < s.hasta)
           then 'lider'::public.nivel
           else p.nivel
         end
    from public.perfiles p
   where p.id = (select auth.uid()) and p.activo
$$;
revoke execute on function public.mi_nivel() from public, anon;
grant  execute on function public.mi_nivel() to authenticated;

-- ¿Quien llama es el líder (o su sustituto vigente) de este departamento? Operación NO.
create or replace function public._asigna(p_dep text)
returns boolean language sql stable security definer set search_path = ''
as $$ select coalesce(public.mi_nivel() = 'lider' and public.mi_departamento() = p_dep, false) $$;
revoke execute on function public._asigna(text) from public, anon, authenticated;

-- 3. Asignaciones de Limpieza: solo Cleaning Leader -----------------------------------------
--    (mismo cuerpo que 30-PEGAR-equipos.sql / 04 / 27; solo cambia quién puede)
create or replace function public.asignar_limpieza(p_id uuid, p_cleaner uuid, p_orden int, p_tipo public.tipo_limpieza)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas; v_resp uuid;
begin
  if not public._asigna('Limpieza') then raise exception 'Solo el líder de limpieza (o su sustituto) asigna limpiezas.'; end if;
  select * into v from public.limpiezas where id = p_id for update;
  if not found then raise exception 'Esa limpieza no existe.'; end if;
  if v.estado not in ('sin_asignar', 'asignada') then raise exception 'Esa limpieza ya empezó: no se puede reasignar.'; end if;
  if p_cleaner is not null and not exists (
       select 1 from public.perfiles where id = p_cleaner and activo and departamento = 'Limpieza' and nivel = 'operador') then
    raise exception 'Solo se puede asignar a un cleaner activo.';
  end if;
  v_resp := case when p_cleaner is null then null else public._responsable(p_cleaner) end;
  update public.limpiezas
     set asignada_a = v_resp, orden = p_orden, tipo = coalesce(p_tipo, tipo),
         estado = case when v_resp is null then 'sin_asignar' else 'asignada' end::public.estado_limpieza,
         publicada = case when v_resp is null then false else publicada end
   where id = p_id;
  perform public._rehacer_miembros(p_id);
  perform public._evento('asignada' || coalesce(' a ' || public._equipo_txt(v_resp), ''), p_id, null);
end $$;

create or replace function public.publicar_orden(p_fecha date)
returns int language plpgsql security definer set search_path = ''
as $$
declare n int;
begin
  if not public._asigna('Limpieza') then raise exception 'Solo el líder de limpieza (o su sustituto) publica el orden.'; end if;
  update public.limpiezas set publicada = true
   where fecha = p_fecha and asignada_a is not null and not publicada;
  get diagnostics n = row_count;
  insert into public.eventos (quien, que) values ((select auth.uid()), 'orden publicado ' || p_fecha || ' (' || n || ')');
  return n;
end $$;

create or replace function public.guardar_equipo(p_miembros uuid[])
returns uuid language plpgsql security definer set search_path = ''
as $$
declare v_id uuid; v_viejos uuid[]; e record;
begin
  if not public._asigna('Limpieza') then raise exception 'Solo el líder de limpieza (o su sustituto) forma equipos.'; end if;
  p_miembros := array(select distinct x from unnest(p_miembros) x where x is not null);
  if cardinality(p_miembros) not between 2 and 3 then raise exception 'Un equipo es de 2 o 3 cleaners.'; end if;
  if exists (select 1 from unnest(p_miembros) x where not exists (
       select 1 from public.perfiles where id = x and activo and departamento = 'Limpieza' and nivel = 'operador')) then
    raise exception 'Solo cleaners activos.';
  end if;
  -- Sacar a estas personas de sus equipos anteriores (un equipo que se queda con 1 persona se deshace)
  v_viejos := array(select distinct m.equipo_id from public.equipo_miembros m where m.perfil_id = any(p_miembros) and m.hasta is null);
  update public.equipo_miembros set hasta = now() where perfil_id = any(p_miembros) and hasta is null;
  for e in select x as id from unnest(v_viejos) x loop
    if (select count(*) from public.equipo_miembros where equipo_id = e.id and hasta is null) < 2 then
      update public.equipo_miembros set hasta = now() where equipo_id = e.id and hasta is null;
      update public.equipos set activo = false, deshecho_en = now() where id = e.id;
    elsif not exists (select 1 from public.equipo_miembros m join public.equipos q on q.id = m.equipo_id
                      where m.equipo_id = e.id and m.perfil_id = q.responsable and m.hasta is null) then
      update public.equipos set responsable = (select perfil_id from public.equipo_miembros where equipo_id = e.id and hasta is null limit 1) where id = e.id;
    end if;
  end loop;
  insert into public.equipos (responsable, creado_por) values (p_miembros[1], (select auth.uid())) returning id into v_id;
  insert into public.equipo_miembros (equipo_id, perfil_id) select v_id, x from unnest(p_miembros) x;
  perform public._reajustar(p_miembros || coalesce((select array_agg(m.perfil_id) from public.equipo_miembros m where m.equipo_id = any(v_viejos)), '{}'));
  insert into public.eventos (quien, que) values ((select auth.uid()), 'equipo formado: ' || public._equipo_txt(p_miembros[1]));
  return v_id;
end $$;

create or replace function public.deshacer_equipo(p_equipo uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_nom text; v_m uuid[];
begin
  if not public._asigna('Limpieza') then raise exception 'Solo el líder de limpieza (o su sustituto) deshace equipos.'; end if;
  select public._equipo_txt(responsable) into v_nom from public.equipos where id = p_equipo and activo;
  if v_nom is null then raise exception 'Ese equipo no existe o ya se deshizo.'; end if;
  v_m := array(select perfil_id from public.equipo_miembros where equipo_id = p_equipo and hasta is null);
  update public.equipo_miembros set hasta = now() where equipo_id = p_equipo and hasta is null;
  update public.equipos set activo = false, deshecho_en = now() where id = p_equipo;
  perform public._reajustar(v_m);
  insert into public.eventos (quien, que) values ((select auth.uid()), 'equipo deshecho: ' || v_nom);
end $$;

create or replace function public.fijar_entrada(p_fecha date, p_cleaner uuid, p_hora time)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if not public._asigna('Limpieza') then raise exception 'Solo el líder de limpieza (o su sustituto) fija la hora de entrada.'; end if;
  if p_hora is null or p_hora < time '05:00' or p_hora > time '20:00' then raise exception 'La hora tiene que estar entre las 05:00 y las 20:00.'; end if;
  if p_fecha < (now() at time zone 'Europe/Malta')::date then raise exception 'No se cambia la hora de un día que ya pasó.'; end if;
  if not exists (select 1 from public.perfiles where id = p_cleaner and departamento = 'Limpieza' and nivel = 'operador') then
    raise exception 'Ese equipo no existe.';
  end if;
  insert into public.entradas_equipo (fecha, cleaner, hora, fijada_por) values (p_fecha, p_cleaner, p_hora, (select auth.uid()))
  on conflict (fecha, cleaner) do update set hora = excluded.hora, fijada_por = excluded.fijada_por, fijada_en = now();
  insert into public.eventos (quien, que) values ((select auth.uid()),
    'hora de entrada ' || to_char(p_hora, 'HH24:MI') || ' · ' || (select nombre from public.perfiles where id = p_cleaner) || ' · ' || to_char(p_fecha, 'DD/MM'));
end $$;

-- 4. Asignaciones de Drivers: solo Drivers Leader (mismo cuerpo que 21-PEGAR-tablero_bolsas.sql) --
create or replace function public.asignar_tarea(p_id uuid, p_driver uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.pendientes;
begin
  if not public._asigna('Drivers') then raise exception 'Solo el líder de drivers (o su sustituto) asigna.'; end if;
  select * into v from public.pendientes where id = p_id for update;
  if not found or not public._en_driver(v) then raise exception 'Ese pendiente no está esperando a un driver.'; end if;
  if not exists (select 1 from public.perfiles where id = p_driver and activo and departamento = 'Drivers' and nivel = 'operador') then
    raise exception 'Solo se asigna a un driver activo.';
  end if;
  update public.pendientes set tomado_por = p_driver, tomado_en = now(), asignado_por = (select auth.uid()) where id = p_id;
  perform public._evento('asignada a driver por el líder', v.limpieza_id, p_id);
end $$;

-- 5. Nombrar / revocar / consultar sustituciones (solo Operación escribe) ---------------------
create or replace function public.nombrar_sustituto(p_departamento text, p_sustituto uuid,
                                                    p_desde timestamptz, p_hasta timestamptz, p_motivo text)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare v_id uuid; v_nom text;
begin
  if public.mi_nivel() is distinct from 'operacion' then raise exception 'Solo Operación nombra sustitutos.'; end if;
  if p_departamento not in ('Limpieza', 'Linens', 'Drivers') then raise exception 'Departamento no válido.'; end if;
  select nombre into v_nom from public.perfiles
   where id = p_sustituto and activo and departamento = p_departamento and nivel = 'operador';
  if v_nom is null then raise exception 'El sustituto tiene que ser un operador activo de %.', p_departamento; end if;
  if p_desde is null or p_hasta is null or p_hasta <= p_desde then raise exception 'La fecha "hasta" tiene que ser posterior a "desde".'; end if;
  if p_hasta <= now() then raise exception 'Esa sustitución ya habría terminado.'; end if;
  if length(btrim(coalesce(p_motivo, ''))) < 3 then raise exception 'Escribe el motivo.'; end if;
  -- Un solo sustituto por departamento a la vez (evita también duplicados por doble toque)
  perform 1 from public.sustituciones where departamento = p_departamento for update;
  if exists (select 1 from public.sustituciones
              where departamento = p_departamento and revocada_en is null
                and desde < p_hasta and p_desde < hasta) then
    raise exception 'Ya hay un sustituto de % en esas fechas. Revócalo primero.', p_departamento;
  end if;
  insert into public.sustituciones (departamento, sustituto, desde, hasta, motivo, nombrado_por)
  values (p_departamento, p_sustituto, p_desde, p_hasta, left(btrim(p_motivo), 200), (select auth.uid()))
  returning id into v_id;
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
  if public.mi_nivel() is distinct from 'operacion' then raise exception 'Solo Operación revoca sustitutos.'; end if;
  select * into v from public.sustituciones where id = p_id for update;
  if not found then raise exception 'Esa sustitución no existe.'; end if;
  if v.revocada_en is not null then raise exception 'Esa sustitución ya estaba revocada.'; end if;
  if v.hasta <= now() then raise exception 'Esa sustitución ya terminó.'; end if;
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
  if public.mi_nivel() is distinct from 'operacion' then raise exception 'Solo Operación.'; end if;
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
   where s.sustituto = (select auth.uid()) and p.activo and p.departamento = s.departamento
     and s.revocada_en is null and now() >= s.desde and now() < s.hasta
   order by s.hasta desc limit 1
$$;
revoke execute on function public.mi_sustitucion() from public, anon;
grant  execute on function public.mi_sustitucion() to authenticated;
