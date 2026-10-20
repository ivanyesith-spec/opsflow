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
-- 3. Asignaciones de Limpieza: solo Cleaning Leader -----------------------------------------
--    (mismo cuerpo que 30-PEGAR-equipos.sql / 04 / 27; solo cambia quién puede)
create or replace function public.asignar_limpieza(p_id uuid, p_cleaner uuid, p_orden int, p_tipo public.tipo_limpieza)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas; v_resp uuid;
begin
  if not public._asigna('Limpieza') then raise exception using errcode = '42501', message = 'Solo el líder de limpieza (o su sustituto) asigna limpiezas.'; end if;
  select * into v from public.limpiezas where id = p_id for update;
  if not found then raise exception using errcode = '22023', message = 'Esa limpieza no existe.'; end if;
  if v.estado not in ('sin_asignar', 'asignada') then raise exception using errcode = '22023', message = 'Esa limpieza ya empezó: no se puede reasignar.'; end if;
  if p_cleaner is not null and not exists (
       select 1 from public.perfiles where id = p_cleaner and activo and departamento = 'Limpieza' and nivel = 'operador') then
    raise exception using errcode = '22023', message = 'Solo se puede asignar a un cleaner activo.';
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
  if not public._asigna('Limpieza') then raise exception using errcode = '42501', message = 'Solo el líder de limpieza (o su sustituto) publica el orden.'; end if;
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
  if not public._asigna('Limpieza') then raise exception using errcode = '42501', message = 'Solo el líder de limpieza (o su sustituto) forma equipos.'; end if;
  p_miembros := array(select distinct x from unnest(p_miembros) x where x is not null);
  if cardinality(p_miembros) not between 2 and 3 then raise exception using errcode = '22023', message = 'Un equipo es de 2 o 3 cleaners.'; end if;
  if exists (select 1 from unnest(p_miembros) x where not exists (
       select 1 from public.perfiles where id = x and activo and departamento = 'Limpieza' and nivel = 'operador')) then
    raise exception using errcode = '22023', message = 'Solo cleaners activos.';
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
  if not public._asigna('Limpieza') then raise exception using errcode = '42501', message = 'Solo el líder de limpieza (o su sustituto) deshace equipos.'; end if;
  select public._equipo_txt(responsable) into v_nom from public.equipos where id = p_equipo and activo;
  if v_nom is null then raise exception using errcode = '22023', message = 'Ese equipo no existe o ya se deshizo.'; end if;
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
  if not public._asigna('Limpieza') then raise exception using errcode = '42501', message = 'Solo el líder de limpieza (o su sustituto) fija la hora de entrada.'; end if;
  if p_hora is null or p_hora < time '05:00' or p_hora > time '20:00' then raise exception using errcode = '22023', message = 'La hora tiene que estar entre las 05:00 y las 20:00.'; end if;
  if p_fecha < (now() at time zone 'Europe/Malta')::date then raise exception using errcode = '22023', message = 'No se cambia la hora de un día que ya pasó.'; end if;
  if not exists (select 1 from public.perfiles where id = p_cleaner and departamento = 'Limpieza' and nivel = 'operador') then
    raise exception using errcode = '22023', message = 'Ese equipo no existe.';
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
  if not public._asigna('Drivers') then raise exception using errcode = '42501', message = 'Solo el líder de drivers (o su sustituto) asigna.'; end if;
  select * into v from public.pendientes where id = p_id for update;
  if not found or not public._en_driver(v) then raise exception using errcode = '22023', message = 'Ese pendiente no está esperando a un driver.'; end if;
  if not exists (select 1 from public.perfiles where id = p_driver and activo and departamento = 'Drivers' and nivel = 'operador') then
    raise exception using errcode = '22023', message = 'Solo se asigna a un driver activo.';
  end if;
  update public.pendientes set tomado_por = p_driver, tomado_en = now(), asignado_por = (select auth.uid()) where id = p_id;
  perform public._evento('asignada a driver por el líder', v.limpieza_id, p_id);
end $$;

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
-- _puede_ver_foto: igual que en el backend actual; solo cambia "líder de X" por _es_lider('X')
create or replace function public._puede_ver_foto(p_nombre text)
returns boolean language sql stable security definer set search_path = ''
as $$
  select public._lider_limpieza()
  or exists (
    select 1 from public.limpiezas l
    where l.id::text = split_part(p_nombre, '/', 1) and public._soy_miembro(l.id) and public.mi_nivel() is not null)
  or (split_part(p_nombre, '/', 2) = 'basura.jpg' and public.mi_departamento() = 'Drivers' and exists (
    select 1 from public.limpiezas l
    where l.id::text = split_part(p_nombre, '/', 1)
      and (public._es_lider('Drivers') or l.zona = public.mi_zona())))
  or (split_part(p_nombre, '/', 2) = 'bolsa.jpg' and (public.mi_departamento() in ('Drivers', 'Linens')))
$$;

-- bolsas_dia: igual que en el backend actual; solo cambia "líder de X" por _es_lider('X')
create or replace function public.bolsas_dia(p_fecha date)
returns jsonb language plpgsql security definer set search_path = ''
as $$
begin
  if not (public.mi_nivel() = 'operacion' or (public._es_lider_en(array['Linens', 'Drivers', 'Limpieza']))) then
    raise exception 'Solo linens, los líderes u Operación.';
  end if;
  insert into public.bolsas (limpieza_id, propiedad_id, zona, fecha, es_prueba)
  select l.id, l.propiedad_id, l.zona, l.fecha, l.es_prueba from public.limpiezas l
  where l.fecha = p_fecha and l.estado::text <> 'cancelada'
  on conflict (limpieza_id) do nothing;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', b.id, 'estado', b.estado, 'zona', b.zona, 'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo,
      'entrada', to_char(c.hora_entrada, 'HH24:MI'), 'salida', to_char(c.hora_salida, 'HH24:MI'),
      'cancelada', l.estado::text = 'cancelada', 'driver', d.nombre, 'recogida_en', b.recogida_en, 'entregada_en', b.entregada_en,
      'comentario', b.comentario, 'incidencia', b.incidencia,
      'foto', (select f.ruta from public.fotos_cierre f where f.limpieza_id = b.limpieza_id and f.sala = 'bolsa'))
      order by (c.hora_entrada is not null) desc, c.hora_entrada, p.codigo)
    from public.bolsas b join public.limpiezas l on l.id = b.limpieza_id join public.propiedades p on p.id = b.propiedad_id
    join public.checkouts c on c.id = l.checkout_id left join public.perfiles d on d.id = b.driver
    where b.fecha = p_fecha), '[]'::jsonb);
end $$;

-- bolsas_etiquetas: igual que en el backend actual; solo cambia "líder de X" por _es_lider('X')
create or replace function public.bolsas_etiquetas(p_fecha date)
returns table (codigo text, nombre text, fecha date, zona text, qr text)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not (public.mi_nivel() = 'operacion' or (public._es_lider('Linens'))) then
    raise exception 'Solo linens u Operación.';
  end if;
  return query select p.codigo, p.nombre, b.fecha, b.zona::text, 'OPSFLOW-BAG:' || b.token
    from public.bolsas b join public.propiedades p on p.id = b.propiedad_id join public.limpiezas l on l.id = b.limpieza_id
    where b.fecha = p_fecha and l.estado::text <> 'cancelada' order by p.codigo;
end $$;

-- cargar_checkouts: igual que en el backend actual; solo cambia "líder de X" por _es_lider('X')
create or replace function public.cargar_checkouts(p_fecha date, p_texto text, p_confirmar boolean default false)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_nivel public.nivel := public.mi_nivel();
  v_dep   text := public.mi_departamento();
  v_linea text; v_n int := 0; v_m text[];
  v_codigo text; v_sal time; v_ent time;
  v_prop  record;
  v_vistos text[] := '{}';
  v_cargados jsonb := '[]'; v_actualizados jsonb := '[]'; v_rechazados jsonb := '[]';
  v_buenas jsonb := '[]';
  v_b jsonb;
begin
  if not (v_nivel = 'operacion' or (public._es_lider('Limpieza'))) then
    raise exception 'Solo Operación o el líder de limpieza pueden cargar checkouts.';
  end if;
  if p_fecha is null then raise exception 'Falta la fecha.'; end if;

  foreach v_linea in array regexp_split_to_array(coalesce(p_texto, ''), E'\\r?\\n') loop
    v_n := v_n + 1;
    v_linea := btrim(v_linea);
    continue when v_linea = '';

    v_m := regexp_match(v_linea, '^(\S+)\s+(\d{1,2})[:.](\d{2})(?:\s+(\d{1,2})[:.](\d{2}))?$');
    if v_m is null then
      v_rechazados := v_rechazados || jsonb_build_object('linea', v_n, 'texto', v_linea, 'motivo', 'Formato: CÓDIGO HH:MM o CÓDIGO HH:MM HH:MM');
      continue;
    end if;

    v_codigo := upper(v_m[1]);
    if v_m[2]::int > 23 or v_m[3]::int > 59 or (v_m[4] is not null and (v_m[4]::int > 23 or v_m[5]::int > 59)) then
      v_rechazados := v_rechazados || jsonb_build_object('linea', v_n, 'texto', v_linea, 'motivo', 'Hora no válida');
      continue;
    end if;
    v_sal := make_time(v_m[2]::int, v_m[3]::int, 0);
    v_ent := case when v_m[4] is null then null else make_time(v_m[4]::int, v_m[5]::int, 0) end;
    if v_ent is not null and v_ent < v_sal then
      v_rechazados := v_rechazados || jsonb_build_object('linea', v_n, 'texto', v_linea, 'motivo', 'La entrada es antes que la salida');
      continue;
    end if;

    if v_codigo = any(v_vistos) then
      v_rechazados := v_rechazados || jsonb_build_object('linea', v_n, 'texto', v_linea, 'motivo', 'Código repetido en esta carga');
      continue;
    end if;

    select id, codigo, es_prueba, activa into v_prop from public.propiedades where codigo = v_codigo;
    if not found then
      v_rechazados := v_rechazados || jsonb_build_object('linea', v_n, 'texto', v_linea, 'motivo', 'Ese código no existe');
      continue;
    end if;
    if not v_prop.activa then
      v_rechazados := v_rechazados || jsonb_build_object('linea', v_n, 'texto', v_linea, 'motivo', 'Propiedad desactivada');
      continue;
    end if;

    v_vistos := v_vistos || v_codigo;
    v_b := jsonb_build_object('codigo', v_codigo, 'salida', to_char(v_sal, 'HH24:MI'),
                              'entrada', to_char(v_ent, 'HH24:MI'));
    if exists (select 1 from public.checkouts where propiedad_id = v_prop.id and fecha = p_fecha) then
      v_actualizados := v_actualizados || v_b;
    else
      v_cargados := v_cargados || v_b;
    end if;
    v_buenas := v_buenas || (v_b || jsonb_build_object('pid', v_prop.id, 'prueba', v_prop.es_prueba));
  end loop;

  if p_confirmar then
    insert into public.checkouts (propiedad_id, fecha, hora_salida, hora_entrada, es_prueba, cargado_por)
    select (x->>'pid')::uuid, p_fecha, (x->>'salida')::time, nullif(x->>'entrada', '')::time,
           (x->>'prueba')::boolean, (select auth.uid())
    from jsonb_array_elements(v_buenas) x
    on conflict (propiedad_id, fecha) do update
      set hora_salida = excluded.hora_salida, hora_entrada = excluded.hora_entrada,
          cargado_por = excluded.cargado_por, cargado_en = now();
  end if;

  return jsonb_build_object('guardado', p_confirmar and jsonb_array_length(v_buenas) > 0,
                            'cargados', v_cargados, 'actualizados', v_actualizados, 'rechazados', v_rechazados);
end $$;

-- entradas_dia: igual que en el backend actual; solo cambia "líder de X" por _es_lider('X')
create or replace function public.entradas_dia(p_fecha date)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
begin
  if not (public._lider_limpieza() or (public._es_lider('Drivers'))) then
    raise exception 'Solo los líderes u Operación.';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object('cleaner', p.id, 'nombre', public._equipo_txt(p.id), 'zona', p.zona,
      'hora', to_char(public._hora_entrada(p_fecha, p.id), 'HH24:MI'),
      'fijada', exists (select 1 from public.entradas_equipo e where e.fecha = p_fecha and e.cleaner = p.id),
      'limpiezas', (select count(*) from public.limpiezas l where l.fecha = p_fecha and l.asignada_a = p.id and l.estado::text <> 'cancelada'))
      order by public._equipo_txt(p.id))
    from public.perfiles p
    where exists (select 1 from public.limpiezas l where l.fecha = p_fecha and l.asignada_a = p.id and l.estado::text <> 'cancelada')), '[]'::jsonb);
end $$;

-- horario_dia: igual que en el backend actual; solo cambia "líder de X" por _es_lider('X')
create or replace function public.horario_dia(p_fecha date)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
begin
  if not (public._lider_limpieza() or (public._es_lider('Drivers'))) then
    raise exception 'Solo los líderes u Operación.';
  end if;
  return coalesce((select jsonb_object_agg(h.limpieza_id, jsonb_build_object(
      'inicio', to_char(h.inicio at time zone 'Europe/Malta', 'HH24:MI'), 'fin', to_char(h.fin at time zone 'Europe/Malta', 'HH24:MI'),
      'primera', h.primera, 'real', h.real_inicio, 'minutos', h.minutos))
    from (select distinct asignada_a from public.limpiezas where fecha = p_fecha and asignada_a is not null) e,
         public._horario_equipo(p_fecha, e.asignada_a) h), '{}'::jsonb);
end $$;

-- marcar_entregado: igual que en el backend actual; solo cambia "líder de X" por _es_lider('X')
create or replace function public.marcar_entregado(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.pendientes;
begin
  select * into v from public.pendientes where id = p_id for update;
  if not found then raise exception 'Ese pendiente no existe.'; end if;
  -- Lo hace quien la cogió; si nadie la cogió, cualquier driver de esa zona; siempre el líder u Operación
  if v.tomado_por is not null and v.tomado_por <> (select auth.uid())
     and not (public.mi_nivel() = 'operacion' or (public._es_lider('Drivers'))) then
    raise exception 'Another driver is on this job.';
  end if;
  if not (public.mi_nivel() = 'operacion'
          or (public._es_lider('Drivers'))
          or (public.mi_nivel() = 'operador' and public.mi_departamento() = 'Drivers' and (public.mi_zona() = v.zona or coalesce(v.tomado_por = (select auth.uid()), false)))) then
    raise exception 'Solo el driver de la zona puede marcar la entrega.';
  end if;
  if v.tipo = 'linens' and v.estado = 'preparado' then
    update public.pendientes set estado = 'entregado', entregado_por = (select auth.uid()), entregado_en = now() where id = p_id;
    perform public._evento('entregado por driver', v.limpieza_id, p_id);
  elsif v.tipo::text = 'utiles' and v.estado = 'preparado' then
    -- Utiles: el driver los deja en el apto y queda cerrado (no hay nadie que marque recibido)
    update public.pendientes set estado = 'cerrado', entregado_por = (select auth.uid()), entregado_en = now(),
                                 cerrado_por = (select auth.uid()), cerrado_en = now() where id = p_id;
    perform public._evento('útiles entregados por driver', v.limpieza_id, p_id);
  elsif v.tipo = 'recogida' and v.estado = 'abierto' then
    update public.pendientes set estado = 'cerrado', entregado_por = (select auth.uid()), entregado_en = now(),
                                 cerrado_por = (select auth.uid()), cerrado_en = now() where id = p_id;
    perform public._evento('recogido por driver', v.limpieza_id, p_id);
  else
    raise exception 'Ese pendiente todavía no está listo para el driver.';
  end if;
end $$;

-- no_pude_entregar: igual que en el backend actual; solo cambia "líder de X" por _es_lider('X')
create or replace function public.no_pude_entregar(p_id uuid, p_motivo text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.pendientes;
begin
  select * into v from public.pendientes where id = p_id for update;
  if not found then raise exception 'Ese pendiente no existe.'; end if;
  -- Lo hace quien la cogió; si nadie la cogió, cualquier driver de esa zona; siempre el líder u Operación
  if v.tomado_por is not null and v.tomado_por <> (select auth.uid())
     and not (public.mi_nivel() = 'operacion' or (public._es_lider('Drivers'))) then
    raise exception 'Another driver is on this job.';
  end if;
  if not (public.mi_nivel() = 'operacion'
          or (public._es_lider('Drivers'))
          or (public.mi_nivel() = 'operador' and public.mi_departamento() = 'Drivers' and (public.mi_zona() = v.zona or coalesce(v.tomado_por = (select auth.uid()), false)))) then
    raise exception 'Solo el driver de la zona puede marcarlo.';
  end if;
  if not ((v.tipo::text in ('linens', 'utiles') and v.estado = 'preparado') or (v.tipo = 'recogida' and v.estado = 'abierto')) then
    raise exception 'Ese pendiente no está en manos del driver.';
  end if;
  if length(btrim(coalesce(p_motivo, ''))) < 3 then raise exception 'Write the reason.'; end if;
  update public.pendientes set incidencia = left(btrim(p_motivo), 200), incidencia_en = now() where id = p_id;
  perform public._evento('no se pudo entregar: ' || left(btrim(p_motivo), 200), v.limpieza_id, p_id);
end $$;

-- marcar_preparado: igual que en el backend actual; solo cambia "líder de X" por _es_lider('X')
create or replace function public.marcar_preparado(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.pendientes;
begin
  select * into v from public.pendientes where id = p_id for update;
  if not found or v.tipo::text not in ('linens', 'utiles') then raise exception 'Ese pendiente no se prepara.'; end if;
  -- Linens lo prepara linens; los utiles (escoba, squeegee, recogedor) los prepara bodega
  if not (public.mi_nivel() = 'operacion'
          or (public._es_lider(case when v.tipo::text = 'utiles' then 'Bodega' else 'Linens' end))) then
    raise exception 'Solo % u Operación marcan preparado.', case when v.tipo::text = 'utiles' then 'bodega' else 'linens' end;
  end if;
  if v.estado <> 'abierto' then raise exception 'Ese pendiente ya está preparado.'; end if;
  update public.pendientes set estado = 'preparado', preparado_por = (select auth.uid()), preparado_en = now() where id = p_id;
  perform public._evento('preparado por ' || case when v.tipo::text = 'utiles' then 'bodega' else 'linens' end, v.limpieza_id, p_id);
end $$;

-- preparar_bolsa: igual que en el backend actual; solo cambia "líder de X" por _es_lider('X')
create or replace function public.preparar_bolsa(p_bolsa uuid, p_lista boolean default true)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.bolsas;
begin
  if not (public.mi_nivel() = 'operacion' or (public._es_lider('Linens'))) then
    raise exception 'Solo linens u Operación preparan bolsas.';
  end if;
  select * into v from public.bolsas where id = p_bolsa for update;
  if not found then raise exception 'Esa bolsa no existe.'; end if;
  if v.estado not in ('por_preparar', 'preparada') then raise exception 'Esa bolsa ya la tiene un driver.'; end if;
  if exists (select 1 from public.limpiezas where id = v.limpieza_id and estado::text = 'cancelada') then raise exception 'Esa limpieza está cancelada.'; end if;
  update public.bolsas set estado = case when p_lista then 'preparada' else 'por_preparar' end,
         preparada_por = case when p_lista then (select auth.uid()) end, preparada_en = case when p_lista then now() end
   where id = p_bolsa;
  perform public._evento(case when p_lista then 'bolsa preparada' else 'bolsa vuelve a por preparar' end, v.limpieza_id, null);
end $$;

-- resolver_incidencia: igual que en el backend actual; solo cambia "líder de X" por _es_lider('X')
create or replace function public.resolver_incidencia(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.pendientes;
begin
  if not (public.mi_nivel() = 'operacion' or (public._es_lider('Drivers'))) then
    raise exception 'Solo el líder de drivers u Operación.';
  end if;
  select * into v from public.pendientes where id = p_id for update;
  if not found or v.incidencia is null then raise exception 'Ese pendiente no tiene incidencia.'; end if;
  update public.pendientes set incidencia = null, incidencia_en = null where id = p_id;
  perform public._evento('incidencia resuelta: ' || v.incidencia, v.limpieza_id, p_id);
end $$;

-- rutas_hoy: igual que en el backend actual; solo cambia "líder de X" por _es_lider('X')
create or replace function public.rutas_hoy()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
begin
  if not (public.mi_nivel() = 'operacion' or (public._es_lider('Drivers'))) then
    raise exception 'Solo el líder de drivers u Operación.';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object('driver', p.nombre, 'zona', p.zona, 'calculada_en', r.calculada_en, 'datos', r.datos) order by p.nombre)
    from public.rutas_driver r join public.perfiles p on p.id = r.driver
    where r.fecha = (now() at time zone 'Europe/Malta')::date and p.activo), '[]'::jsonb);
end $$;

-- avisos_para: igual que en el backend actual; solo cambia "líder de X" por _es_lider('X')
create or replace function public.avisos_para(p_tipo text, p_id uuid default null, p_fecha date default null)
returns table (perfil_id uuid, titulo text, cuerpo text, url text, clave text, telefonos jsonb)
language plpgsql security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  pe public.pendientes; li public.limpiezas; pr public.propiedades; ck public.checkouts;
  v_aviso text; v_ok boolean := true;
begin
  create temp table if not exists _dest (perfil_id uuid, idioma text, t_es text, t_en text, c_es text, c_en text, url text, clave text) on commit drop;
  truncate _dest;

  if p_tipo = 'pendiente' then
    select * into pe from public.pendientes where id = p_id;
    if not found then return; end if;
    select * into pr from public.propiedades where id = pe.propiedad_id;
    select c.* into ck from public.checkouts c join public.limpiezas l on l.checkout_id = c.id where l.id = pe.limpieza_id;
    v_aviso := 'pendiente:' || pe.id || ':' || pe.estado;

    if pe.asignado_por is not null and pe.tomado_por is not null and pe.tomado_en > now() - interval '2 minutes' then
      -- 14. El líder asigna una tarea a un driver concreto → ese driver
      insert into _dest select p.id, p.idioma,
        'Asignado a ti: ' || pr.codigo, 'Assigned to you: ' || pr.codigo,
        pr.pueblo || ' · ' || case when pe.tipo = 'recogida' then 'recoger' else 'entregar' end,
        pr.pueblo || ' · ' || case when pe.tipo = 'recogida' then 'pick up' else 'deliver' end,
        './', 'pendiente:' || pe.id || ':asignado:' || extract(epoch from pe.tomado_en)::bigint || ':' || p.id
      from public.perfiles p where p.activo and p.id = pe.tomado_por;

    elsif pe.incidencia is not null and pe.incidencia_en > now() - interval '2 minutes'
       and ((pe.tipo::text in ('linens', 'utiles') and pe.estado = 'preparado') or (pe.tipo = 'recogida' and pe.estado = 'abierto')) then
      -- 11. El driver no pudo entregar/recoger → lider de drivers
      insert into _dest select p.id, p.idioma,
        'No se pudo entregar: ' || pr.codigo, 'Couldn''t deliver: ' || pr.codigo,
        pr.pueblo || ' · ' || pe.incidencia, pr.pueblo || ' · ' || pe.incidencia,
        './?v=drivers', 'pendiente:' || pe.id || ':incidencia:' || extract(epoch from pe.incidencia_en)::bigint || ':' || p.id
      from public.perfiles p where p.activo and public._es_lider_id(p.id, 'Drivers')
        and (p.zona is null or p.zona = pe.zona or p.nivel = 'operador');

    elsif pe.tipo = 'linens' and pe.estado = 'abierto' then
      -- 2. Cleaner reporta linens → lider de linens
      insert into _dest select p.id, p.idioma,
        'Linens: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'es') end, 'Linens: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'en') end,
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        './?v=linens', null
      from public.perfiles p where p.activo and public._es_lider_id(p.id, 'Linens')
        and (p.zona is null or p.zona = pe.zona or p.nivel = 'operador');

    elsif pe.tipo = 'linens' and pe.estado = 'preparado' then
      -- 3. Linens preparado → drivers de la zona
      insert into _dest select p.id, p.idioma,
        'Entregar: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'es') end, 'Deliver: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'en') end,
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Guest arrives ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        './', null
      from public.perfiles p where p.activo and p.nivel = 'operador' and p.departamento = 'Drivers' and p.zona = pe.zona;

    elsif pe.tipo = 'recogida' and pe.estado = 'abierto' and pe.listo_a is not null then
      -- 15. El cleaner avisa "listo en 30 min" → drivers de la zona
      insert into _dest select p.id, p.idioma,
        'Listo a las ' || to_char(pe.listo_a at time zone 'Europe/Malta', 'HH24:MI') || ': ' || pr.codigo,
        'Ready at ' || to_char(pe.listo_a at time zone 'Europe/Malta', 'HH24:MI') || ': ' || pr.codigo,
        pr.pueblo || ' · recoger basura y linens sucios', pr.pueblo || ' · pick up trash & dirty linens',
        './', null
      from public.perfiles p where p.activo and p.nivel = 'operador' and p.departamento = 'Drivers' and p.zona = pe.zona;

    elsif pe.tipo = 'recogida' and pe.estado = 'abierto' and pe.foto is not null then
      -- 4b. Basura dejada en el apto (con foto) → drivers de la zona y lider de drivers
      insert into _dest select p.id, p.idioma,
        'Basura en el apto: ' || pr.codigo, 'Trash left: ' || pr.codigo,
        pr.pueblo || ' · ' || pe.detalle, pr.pueblo || ' · pick it up (photo in the app)',
        './', null
      from public.perfiles p where p.activo and p.departamento = 'Drivers'
        and ((p.nivel = 'operador' and p.zona = pe.zona) or (public._es_lider_id(p.id, 'Drivers') and (p.zona is null or p.zona = pe.zona or p.nivel = 'operador')));

    elsif pe.tipo::text = 'utiles' and pe.estado = 'abierto' then
      -- 8. Faltan utiles → lider de bodega
      insert into _dest select p.id, p.idioma,
        'Útiles: ' || pe.detalle, 'Tools: ' || pe.detalle,
        pr.codigo || ' · ' || pr.pueblo, pr.codigo || ' · ' || pr.pueblo,
        './?v=bodega', null
      from public.perfiles p where p.activo and public._es_lider_id(p.id, 'Bodega')
        and (p.zona is null or p.zona = pe.zona or p.nivel = 'operador');

    elsif pe.tipo::text = 'utiles' and pe.estado = 'preparado' then
      -- 9. Utiles preparados → drivers de la zona
      insert into _dest select p.id, p.idioma,
        'Entregar útiles: ' || pe.detalle, 'Deliver tools: ' || pe.detalle,
        pr.codigo || ' · ' || pr.pueblo, pr.codigo || ' · ' || pr.pueblo,
        './', null
      from public.perfiles p where p.activo and p.nivel = 'operador' and p.departamento = 'Drivers' and p.zona = pe.zona;

    elsif pe.tipo = 'recogida' and pe.estado = 'abierto' then
      -- 4. Recogida → drivers de la zona
      insert into _dest select p.id, p.idioma,
        'Recoger: basura y linens sucios', 'Pick up: trash & dirty linens',
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Guest arrives ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        './', null
      from public.perfiles p where p.activo and p.nivel = 'operador' and p.departamento = 'Drivers' and p.zona = pe.zona;

    elsif pe.tipo = 'linens' and pe.estado = 'entregado' then
      -- 5. Entregado → el cleaner que lo pidio
      insert into _dest select p.id, p.idioma,
        'Entregado: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'es') end, 'Delivered: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'en') end,
        pr.codigo || ' · marca Recibido', pr.codigo || ' · tap Received',
        './', null
      from public.perfiles p where p.activo and p.id = pe.creado_por;

    elsif pe.tipo = 'otro' and pe.estado = 'abierto' then
      -- 7. Pendiente "otro" → lider de limpieza
      insert into _dest select p.id, p.idioma,
        'Pendiente: ' || pe.detalle, 'Issue: ' || pe.detalle,
        pr.codigo || ' · ' || pr.pueblo, pr.codigo || ' · ' || pr.pueblo,
        './?v=seguimiento', null
      from public.perfiles p where p.activo and public._es_lider_id(p.id, 'Limpieza')
        and (p.zona is null or p.zona = pe.zona or p.nivel = 'operador');
    end if;

    if pe.prioritario then
      update _dest set t_es = '⚠ ' || t_es, t_en = '⚠ ' || t_en where true;  -- Supabase exige WHERE en todo UPDATE
    end if;

  elsif p_tipo = 'limpieza' then
    select * into li from public.limpiezas where id = p_id;
    if not found then return; end if;
    select * into pr from public.propiedades where id = li.propiedad_id;
    if li.estado = 'terminada' and li.cierre->>'llaves' = 'false' then
      -- 10. Llaves NO dejadas en el key box → lider de limpieza y lider de drivers (urgente)
      insert into _dest select p.id, p.idioma,
        '⚠ Llaves NO en el key box: ' || pr.codigo, '⚠ Keys NOT in the key box: ' || pr.codigo,
        pr.pueblo || coalesce(' · ' || (li.cierre->>'motivo_llaves'), ''), pr.pueblo || coalesce(' · ' || (li.cierre->>'motivo_llaves'), ''),
        case when p.departamento = 'Limpieza' then './?v=seguimiento' else './' end, 'limpieza:' || li.id || ':llaves:' || p.id
      from public.perfiles p
      where p.activo and (public._es_lider_id(p.id, 'Limpieza') or public._es_lider_id(p.id, 'Drivers')) and (p.zona is null or p.zona = li.zona or p.nivel = 'operador');
      v_aviso := 'limpieza:' || li.id || ':llaves';
    elsif li.estado::text = 'cancelada' and li.publicada then
      -- 12. Limpieza cancelada → su cleaner
      insert into _dest select p.id, p.idioma,
        'Cancelada: ' || pr.codigo, 'Cancelled: ' || pr.codigo,
        pr.pueblo || coalesce(' · ' || li.cancelada_motivo, ''), pr.pueblo || coalesce(' · ' || li.cancelada_motivo, ''),
        './', 'limpieza:' || li.id || ':cancelada:' || p.id
      from public.perfiles p where p.activo and p.id = any(public._miembros_de(li.id));
      v_aviso := 'limpieza:' || li.id || ':cancelada';
    elsif li.estado = 'asignada' and li.publicada and li.reabierta_en > now() - interval '2 minutes' then
      -- 13. Limpieza reabierta (tras "no pude entrar") → su cleaner
      insert into _dest select p.id, p.idioma,
        'Reabierta: ' || pr.codigo, 'Reopened: ' || pr.codigo,
        pr.pueblo || ' · vuelve a tu lista', pr.pueblo || ' · back on your list',
        './', 'limpieza:' || li.id || ':reabierta:' || extract(epoch from li.reabierta_en)::bigint || ':' || p.id
      from public.perfiles p where p.activo and p.id = any(public._miembros_de(li.id));
      v_aviso := 'limpieza:' || li.id || ':reabierta';
    elsif li.estado <> 'no_pude_entrar' then
      return;
    else
    v_aviso := 'limpieza:' || li.id || ':' || li.estado;
    -- 6. No pude entrar → lider de limpieza, lider de drivers y drivers de la zona
    insert into _dest select p.id, p.idioma,
      'No pudo entrar: ' || pr.codigo, 'Couldn''t get in: ' || pr.codigo,
      pr.pueblo || coalesce(' · ' || li.motivo_no_entrar, ''), pr.pueblo || coalesce(' · ' || li.motivo_no_entrar, ''),
      case when public._es_lider_id(p.id, 'Limpieza') then './?v=seguimiento' else './' end, null
    from public.perfiles p
    where p.activo and (
         ((public._es_lider_id(p.id, 'Limpieza') or public._es_lider_id(p.id, 'Drivers')) and (p.zona is null or p.zona = li.zona or p.nivel = 'operador'))
      or (p.nivel = 'operador' and p.departamento = 'Drivers' and p.zona = li.zona));
    end if;

  elsif p_tipo = 'orden' then
    if p_fecha is null then return; end if;
    -- 1. Orden publicado → cada cleaner con limpiezas publicadas ese dia
    --    (la clave lleva cuantas tiene: si el lider le anade otra y publica, le vuelve a sonar)
    insert into _dest select p.id, p.idioma,
      'Orden de limpieza listo', 'Your cleaning order is ready',
      to_char(p_fecha, 'DD/MM') || ' · ' || count(*) || ' apartamento' || case when count(*) > 1 then 's' else '' end,
      to_char(p_fecha, 'DD/MM') || ' · ' || count(*) || ' apartment' || case when count(*) > 1 then 's' else '' end,
      './', 'orden:' || p_fecha || ':' || p.id || ':' || count(*)
    from public.limpiezas l join public.perfiles p on p.id = any(public._miembros_de(l.id))
    where l.fecha = p_fecha and l.publicada and p.activo
    group by p.id, p.idioma;

  else
    return;
  end if;

  update _dest set clave = coalesce(clave, v_aviso || ':' || _dest.perfil_id) where true;

  -- Apuntar los nuevos; los que ya estaban apuntados no salen otra vez
  return query
  with nuevos as (
    insert into public.avisos_enviados (clave, perfil_id, titulo)
    select d.clave, d.perfil_id, case when d.idioma = 'es' then d.t_es else d.t_en end from _dest d
    on conflict (clave) do nothing
    returning avisos_enviados.clave
  )
  select d.perfil_id,
         case when d.idioma = 'es' then d.t_es else d.t_en end,
         case when d.idioma = 'es' then d.c_es else d.c_en end,
         d.url, d.clave,
         coalesce((select jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth))
                   from public.suscripciones s where s.perfil_id = d.perfil_id), '[]'::jsonb)
  from _dest d join nuevos n on n.clave = d.clave;
end $$;

drop policy if exists "perfiles: lectura por nivel" on public.perfiles;
create policy "perfiles: lectura por nivel"
on public.perfiles for select to authenticated
using (
  id = (select auth.uid())
  or public._es_lider(departamento)
  or (select public.mi_nivel()) = 'operacion'
);

drop policy if exists "propiedades: leen lideres y operacion" on public.propiedades;
create policy "propiedades: leen lideres y operacion"
on public.propiedades for select to authenticated
using ((select public.mi_nivel()) in ('lider', 'operacion') or (select public._soy_sustituto()));

drop policy if exists "checkouts: leen lideres y operacion" on public.checkouts;
create policy "checkouts: leen lideres y operacion"
on public.checkouts for select to authenticated
using ((select public.mi_nivel()) in ('lider', 'operacion') or (select public._soy_sustituto()));

drop policy if exists "limpiezas: lectura por rol" on public.limpiezas;
create policy "limpiezas: lectura por rol" on public.limpiezas for select to authenticated using (
  (select public.mi_nivel()) = 'operacion'
  or ((select public._es_lider_en(array['Limpieza', 'Drivers'])))
  or ((select public.mi_nivel()) = 'operador' and (select public.mi_departamento()) = 'Limpieza'
       and publicada and public._soy_miembro(id))
  or ((select public.mi_nivel()) = 'operador' and (select public.mi_departamento()) = 'Drivers'
       and publicada and zona = (select public.mi_zona()))
);

drop policy if exists "pendientes: lectura por rol" on public.pendientes;
create policy "pendientes: lectura por rol" on public.pendientes for select to authenticated using (
  (select public.mi_nivel()) = 'operacion'
  or ((select public._es_lider('Limpieza')))
  or ((select public._es_lider('Linens')) and tipo::text = 'linens')
  or ((select public._es_lider('Bodega')) and tipo::text = 'utiles')
  or ((select public._es_lider('Drivers')) and tipo::text in ('linens', 'recogida', 'utiles'))
  or ((select public.mi_nivel()) = 'operador' and (select public.mi_departamento()) = 'Limpieza'
       and public._soy_miembro(limpieza_id))
  or ((select public.mi_nivel()) = 'operador' and (select public.mi_departamento()) = 'Drivers'
       and (tipo::text = 'recogida' or (tipo::text in ('linens', 'utiles') and estado <> 'abierto')))
);

drop policy if exists "bolsas: lectura" on public.bolsas;
create policy "bolsas: lectura" on public.bolsas for select to authenticated using (
  (select public.mi_nivel()) = 'operacion'
  or ((select public._es_lider_en(array['Linens', 'Drivers', 'Limpieza'])))
  or ((select public.mi_departamento()) = 'Drivers' and (select public.mi_nivel()) = 'operador')
  or public._soy_miembro(limpieza_id)
);

drop policy if exists "entradas: lectura" on public.entradas_equipo;
create policy "entradas: lectura" on public.entradas_equipo for select to authenticated using (
  (select public.mi_nivel()) = 'operacion'
  or (select public._es_lider_en(array['Limpieza', 'Drivers']))
  or (select public.mi_departamento()) = 'Drivers'
  or cleaner = (select auth.uid())
);

drop policy if exists "rutas: lectura" on public.rutas_driver;
create policy "rutas: lectura" on public.rutas_driver for select to authenticated using (
  driver = (select auth.uid())
  or (select public.mi_nivel()) = 'operacion'
  or ((select public._es_lider('Drivers'))));

drop policy if exists "equipos: lectura" on public.equipos;
create policy "equipos: lectura" on public.equipos for select to authenticated using (
  ((select public.mi_nivel()) = 'operacion' or ((select public._es_lider('Limpieza'))))
  or exists (select 1 from public.equipo_miembros m where m.equipo_id = equipos.id and m.perfil_id = (select auth.uid())));

drop policy if exists "equipo_miembros: lectura" on public.equipo_miembros;
create policy "equipo_miembros: lectura" on public.equipo_miembros for select to authenticated using (
  ((select public.mi_nivel()) = 'operacion' or ((select public._es_lider('Limpieza')))) or perfil_id = (select auth.uid()));

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
