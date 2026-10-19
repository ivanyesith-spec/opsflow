-- OpsFlow · equipos de limpieza: 2–3 personas en el mismo apartamento, cada una con su cuenta (12 oct 2026)
-- SPEC-equipos.md (aprobado). Ejecutar DESPUES de 027. Se puede ejecutar varias veces. Todo UPDATE/DELETE lleva WHERE.
--   · La líder forma equipos (2–3 cleaners). Se asigna al equipo: todos ven los mismos apartamentos.
--   · Cada sala es de quien marca primero un paso en ella; los demás la ven bloqueada. "final" es común.
--   · Quien llega escanea el QR (o "I'm here"): queda registrado. Un cleaner sin equipo funciona igual que hoy.
--   · limpiezas.asignada_a se mantiene (= responsable del equipo) para no romper nada de lo anterior.

-- 1. Tablas ---------------------------------------------------------------------------------
create table if not exists public.equipos (
  id           uuid primary key default gen_random_uuid(),
  responsable  uuid not null references public.perfiles(id),
  activo       boolean not null default true,
  creado_por   uuid, creado_en timestamptz not null default now(), deshecho_en timestamptz
);
create table if not exists public.equipo_miembros (
  equipo_id    uuid not null references public.equipos(id) on delete cascade,
  perfil_id    uuid not null references public.perfiles(id),
  desde        timestamptz not null default now(),
  hasta        timestamptz,
  primary key (equipo_id, perfil_id)
);
-- Un cleaner solo puede estar en un equipo activo
create unique index if not exists equipo_miembros_uno on public.equipo_miembros (perfil_id) where hasta is null;

-- Quiénes forman el equipo de cada limpieza (foto fija al asignar; no cambia cuando ya empezó)
create table if not exists public.limpieza_miembros (
  limpieza_id  uuid not null references public.limpiezas(id) on delete cascade,
  perfil_id    uuid not null references public.perfiles(id),
  primary key (limpieza_id, perfil_id)
);
-- Quién llegó al apartamento (con QR o "I'm here") y cuándo
create table if not exists public.limpieza_personas (
  limpieza_id  uuid not null references public.limpiezas(id) on delete cascade,
  perfil_id    uuid not null references public.perfiles(id),
  llegada_en   timestamptz not null default now(),
  llegada_qr   boolean not null default false,
  gps          jsonb,
  primary key (limpieza_id, perfil_id)
);
-- Quién lleva cada sala (la clave garantiza UN solo dueño por sala)
create table if not exists public.limpieza_salas (
  limpieza_id  uuid not null references public.limpiezas(id) on delete cascade,
  sala         text not null check (sala in ('kitchen', 'bathroom', 'bedroom', 'living')),
  perfil_id    uuid not null references public.perfiles(id),
  desde        timestamptz not null default now(),
  terminada_en timestamptz,
  primary key (limpieza_id, sala)
);

do $$ declare t text; begin
  foreach t in array array['equipos', 'equipo_miembros', 'limpieza_miembros', 'limpieza_personas', 'limpieza_salas'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('revoke insert, update, delete, truncate on public.%I from authenticated', t);
  end loop;
end $$;
-- Lectura: los líderes de limpieza y Operación todo; cada cleaner lo de sus limpiezas y su equipo
drop policy if exists "equipos: lectura" on public.equipos;
create policy "equipos: lectura" on public.equipos for select to authenticated using (
  ((select public.mi_nivel()) = 'operacion' or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) = 'Limpieza'))
  or exists (select 1 from public.equipo_miembros m where m.equipo_id = equipos.id and m.perfil_id = (select auth.uid())));
drop policy if exists "equipo_miembros: lectura" on public.equipo_miembros;
create policy "equipo_miembros: lectura" on public.equipo_miembros for select to authenticated using (
  ((select public.mi_nivel()) = 'operacion' or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) = 'Limpieza')) or perfil_id = (select auth.uid()));

-- 2. Ayudantes ------------------------------------------------------------------------------
-- Miembros de una limpieza: la foto fija + el responsable (asignada_a), por si es una limpieza antigua
create or replace function public._miembros_de(p_l uuid)
returns uuid[] language sql stable security definer set search_path = ''
as $$
  select coalesce(array(
    select m.perfil_id from public.limpieza_miembros m where m.limpieza_id = p_l
    union select l.asignada_a from public.limpiezas l where l.id = p_l and l.asignada_a is not null), '{}')
$$;
create or replace function public._soy_miembro(p_l uuid)
returns boolean language sql stable security definer set search_path = ''
as $$ select (select auth.uid()) = any(public._miembros_de(p_l)) $$;
revoke execute on function public._miembros_de(uuid) from public, anon, authenticated;
revoke execute on function public._soy_miembro(uuid) from public, anon;
grant  execute on function public._soy_miembro(uuid) to authenticated;   -- lo usan las reglas de lectura

-- "Ana + Luis": el equipo activo de una persona (el responsable primero) o su nombre si va sola
create or replace function public._equipo_txt(p_perfil uuid)
returns text language sql stable security definer set search_path = ''
as $$
  select coalesce((
    select string_agg(p.nombre, ' + ' order by (p.id = e.responsable) desc, p.nombre)
    from public.equipo_miembros m0 join public.equipos e on e.id = m0.equipo_id and e.activo
    join public.equipo_miembros m on m.equipo_id = e.id and m.hasta is null
    join public.perfiles p on p.id = m.perfil_id
    where m0.perfil_id = p_perfil and m0.hasta is null),
    (select nombre from public.perfiles where id = p_perfil))
$$;
-- Los nombres del equipo de UNA limpieza (de su foto fija)
create or replace function public._equipo_limpieza_txt(p_l uuid)
returns text language sql stable security definer set search_path = ''
as $$
  select string_agg(p.nombre, ' + ' order by (p.id = l.asignada_a) desc, p.nombre)
  from public.limpiezas l join public.perfiles p on p.id = any(public._miembros_de(l.id))
  where l.id = p_l
$$;
revoke execute on function public._equipo_txt(uuid), public._equipo_limpieza_txt(uuid) from public, anon, authenticated;

-- Rehacer la foto fija de una limpieza que aún no ha empezado: el equipo activo del responsable (o él solo)
create or replace function public._rehacer_miembros(p_l uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_asig uuid;
begin
  select asignada_a into v_asig from public.limpiezas where id = p_l;
  delete from public.limpieza_miembros where limpieza_id = p_l;
  if v_asig is null then return; end if;
  insert into public.limpieza_miembros (limpieza_id, perfil_id)
  select p_l, m.perfil_id from public.equipo_miembros m0
    join public.equipos e on e.id = m0.equipo_id and e.activo
    join public.equipo_miembros m on m.equipo_id = e.id and m.hasta is null
   where m0.perfil_id = v_asig and m0.hasta is null
  union select p_l, v_asig
  on conflict do nothing;
end $$;
-- El responsable del equipo activo de una persona (o ella misma)
create or replace function public._responsable(p_perfil uuid)
returns uuid language sql stable security definer set search_path = ''
as $$
  select coalesce((select e.responsable from public.equipo_miembros m join public.equipos e on e.id = m.equipo_id and e.activo
                   where m.perfil_id = p_perfil and m.hasta is null), p_perfil)
$$;
revoke execute on function public._rehacer_miembros(uuid), public._responsable(uuid) from public, anon, authenticated;

-- Las limpiezas que aún no han empezado de estas personas: pasan al responsable de su equipo y se rehace la foto fija
create or replace function public._reajustar(p_personas uuid[])
returns void language plpgsql security definer set search_path = ''
as $$
declare r record;
begin
  for r in select l.id, l.asignada_a from public.limpiezas l
            where l.estado = 'asignada' and l.fecha >= (now() at time zone 'Europe/Malta')::date
              and (l.asignada_a = any(p_personas)
                   or exists (select 1 from public.limpieza_miembros m where m.limpieza_id = l.id and m.perfil_id = any(p_personas)))
  loop
    update public.limpiezas set asignada_a = public._responsable(r.asignada_a) where id = r.id and asignada_a is distinct from public._responsable(r.asignada_a);
    perform public._rehacer_miembros(r.id);
  end loop;
end $$;
revoke execute on function public._reajustar(uuid[]) from public, anon, authenticated;

-- Las limpiezas que ya existen: su foto fija es su cleaner
insert into public.limpieza_miembros (limpieza_id, perfil_id)
select id, asignada_a from public.limpiezas where asignada_a is not null
on conflict do nothing;

-- ¿Ha llegado esta persona? (las limpiezas empezadas antes de este cambio no tienen llegadas: vale su cleaner)
create or replace function public._presente(p_l uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.limpieza_personas where limpieza_id = p_l and perfil_id = (select auth.uid()))
      or (not exists (select 1 from public.limpieza_personas where limpieza_id = p_l)
          and (select asignada_a from public.limpiezas where id = p_l) = (select auth.uid()))
$$;
-- Tomar una sala (si está libre) o fallar si es de otra persona
create or replace function public._tomar_sala(p_l uuid, p_sala text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_duen uuid; v_nom text;
begin
  if p_sala not in ('kitchen', 'bathroom', 'bedroom', 'living') then return; end if;
  if not public._presente(p_l) then raise exception 'Scan the QR when you arrive (or tap "I''m here") first.'; end if;
  insert into public.limpieza_salas (limpieza_id, sala, perfil_id) values (p_l, p_sala, (select auth.uid()))
  on conflict (limpieza_id, sala) do nothing;
  select perfil_id into v_duen from public.limpieza_salas where limpieza_id = p_l and sala = p_sala;
  if v_duen is distinct from (select auth.uid()) then
    select nombre into v_nom from public.perfiles where id = v_duen;
    raise exception '% already has the %.', split_part(v_nom, ' ', 1),
      case p_sala when 'kitchen' then 'kitchen' when 'bathroom' then 'bathroom' when 'bedroom' then 'bedroom' else 'living room' end;
  end if;
end $$;
-- Sala terminada = todos sus pasos obligatorios hechos
create or replace function public._revisar_sala(p_l uuid, p_sala text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas; v_faltan int;
begin
  select * into v from public.limpiezas where id = p_l;
  select count(*) into v_faltan from public.checklist_pasos p
   where p.tipo = v.tipo and p.activo and p.obligatorio and p.sala = p_sala and not (v.checklist ? p.id::text);
  update public.limpieza_salas set terminada_en = case when v_faltan = 0 then coalesce(terminada_en, now()) end
   where limpieza_id = p_l and sala = p_sala;
end $$;
revoke execute on function public._presente(uuid), public._tomar_sala(uuid, text), public._revisar_sala(uuid, text) from public, anon, authenticated;

-- Al empezar una limpieza, quien la empieza queda como "llegado"
create or replace function public._limpieza_inicio()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if (select auth.uid()) is not null then
    insert into public.limpieza_personas (limpieza_id, perfil_id, llegada_en, llegada_qr, gps)
    values (new.id, (select auth.uid()), now(), coalesce(new.inicio_qr, false), new.gps->'inicio')
    on conflict do nothing;
  end if;
  return new;
end $$;
revoke execute on function public._limpieza_inicio() from public, anon, authenticated;
drop trigger if exists limpiezas_inicio on public.limpiezas;
create trigger limpiezas_inicio after update of estado on public.limpiezas
for each row when (old.estado = 'asignada' and new.estado = 'en_curso') execute function public._limpieza_inicio();

-- 3. Quién ve qué (lo de antes, pero "mía" = soy del equipo de esa limpieza) --------------------
drop policy if exists "limpiezas: lectura por rol" on public.limpiezas;
create policy "limpiezas: lectura por rol" on public.limpiezas for select to authenticated using (
  (select public.mi_nivel()) = 'operacion'
  or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) in ('Limpieza', 'Drivers'))
  or ((select public.mi_nivel()) = 'operador' and (select public.mi_departamento()) = 'Limpieza'
       and publicada and public._soy_miembro(id))
  or ((select public.mi_nivel()) = 'operador' and (select public.mi_departamento()) = 'Drivers'
       and publicada and zona = (select public.mi_zona()))
);
drop policy if exists "pendientes: lectura por rol" on public.pendientes;
create policy "pendientes: lectura por rol" on public.pendientes for select to authenticated using (
  (select public.mi_nivel()) = 'operacion'
  or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) = 'Limpieza')
  or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) = 'Linens' and tipo::text = 'linens')
  or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) = 'Bodega' and tipo::text = 'utiles')
  or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) = 'Drivers' and tipo::text in ('linens', 'recogida', 'utiles'))
  or ((select public.mi_nivel()) = 'operador' and (select public.mi_departamento()) = 'Limpieza'
       and public._soy_miembro(limpieza_id))
  or ((select public.mi_nivel()) = 'operador' and (select public.mi_departamento()) = 'Drivers'
       and (tipo::text = 'recogida' or (tipo::text in ('linens', 'utiles') and estado <> 'abierto')))
);
drop policy if exists "bolsas: lectura" on public.bolsas;
create policy "bolsas: lectura" on public.bolsas for select to authenticated using (
  (select public.mi_nivel()) = 'operacion'
  or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) in ('Linens', 'Drivers', 'Limpieza'))
  or ((select public.mi_departamento()) = 'Drivers' and (select public.mi_nivel()) = 'operador')
  or public._soy_miembro(limpieza_id)
);

-- 4. Funciones de siempre que ahora miran el equipo ------------------------------------------------
create or replace function public._mi_limpieza(p_id uuid)
returns public.limpiezas language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  select * into v from public.limpiezas where id = p_id for update;
  if not found or not public._soy_miembro(p_id) or not v.publicada or public.mi_nivel() is null then
    raise exception 'Esta limpieza no es tuya.';
  end if;
  return v;
end $$;
revoke execute on function public._mi_limpieza(uuid) from public, anon, authenticated;

create or replace function public._puede_subir_foto(p_nombre text)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.limpiezas l
    where l.id::text = split_part(p_nombre, '/', 1)
      and public._soy_miembro(l.id) and l.publicada and l.estado = 'en_curso'
      and public.mi_nivel() is not null)
  or (split_part(p_nombre, '/', 2) = 'bolsa.jpg' and exists (
    select 1 from public.bolsas b
    where b.limpieza_id::text = split_part(p_nombre, '/', 1) and b.driver = (select auth.uid()) and b.estado = 'en_camion'))
$$;
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
      and (public.mi_nivel() = 'lider' or l.zona = public.mi_zona())))
  or (split_part(p_nombre, '/', 2) = 'bolsa.jpg' and (public.mi_departamento() in ('Drivers', 'Linens')))
$$;
revoke execute on function public._puede_subir_foto(text), public._puede_ver_foto(text) from public, anon;
grant  execute on function public._puede_subir_foto(text), public._puede_ver_foto(text) to authenticated;

create or replace function public.marcar_recibido(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.pendientes;
begin
  select * into v from public.pendientes where id = p_id for update;
  if not found then raise exception 'Ese pendiente no existe.'; end if;
  if not public._soy_miembro(v.limpieza_id) or public.mi_nivel() is null then
    raise exception 'Solo el equipo de esta limpieza puede marcar recibido.';
  end if;
  if v.tipo <> 'linens' or v.estado <> 'entregado' then raise exception 'Todavía no se ha entregado.'; end if;
  update public.pendientes set estado = 'cerrado', cerrado_por = (select auth.uid()), cerrado_en = now() where id = p_id;
  perform public._evento('recibido por cleaner: cerrado', v.limpieza_id, p_id);
end $$;

create or replace function public.reportar_pendiente(p_limpieza uuid, p_tipo public.tipo_pendiente, p_detalle text, p_cantidad int default 1)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas; v_prio boolean; v_id uuid;
begin
  select * into v from public.limpiezas where id = p_limpieza;
  if not found then raise exception 'Esa limpieza no existe.'; end if;
  if not public._lider_limpieza() and (not public._soy_miembro(v.id) or not v.publicada) then
    raise exception 'Esta limpieza no es tuya.';
  end if;
  if v.estado not in ('en_curso', 'terminada') then raise exception 'Primero hay que empezar la limpieza.'; end if;
  select (hora_entrada is not null) into v_prio from public.checkouts where id = v.checkout_id;
  insert into public.pendientes (limpieza_id, propiedad_id, zona, fecha, tipo, detalle, cantidad, prioritario, creado_por, es_prueba)
  values (v.id, v.propiedad_id, v.zona, v.fecha, p_tipo,
          coalesce(nullif(btrim(p_detalle), ''), case when p_tipo = 'recogida' then 'Basura y linens sucios' end),
          coalesce(p_cantidad, 1), coalesce(v_prio, false), (select auth.uid()), v.es_prueba)
  returning id into v_id;
  perform public._evento('pendiente reportado (' || p_tipo || ')', v.id, v_id);
  return v_id;
end $$;

-- Asignar: a una persona o a su equipo (se guarda el responsable y la foto fija del equipo)
create or replace function public.asignar_limpieza(p_id uuid, p_cleaner uuid, p_orden int, p_tipo public.tipo_limpieza)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas; v_resp uuid;
begin
  if not public._lider_limpieza() then raise exception 'Solo el líder de limpieza u Operación asignan limpiezas.'; end if;
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

-- Marcar un paso: la sala pasa a ser de quien marca (si está libre); si es de otra persona, no se puede
create or replace function public.marcar_paso(p_id uuid, p_paso int, p_hecho boolean)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas; v_sala text;
begin
  v := public._mi_limpieza(p_id);
  if v.estado <> 'en_curso' then raise exception 'Primero hay que empezar la limpieza.'; end if;
  if v.linens_revisado is null then raise exception 'Check the linens bag first.'; end if;
  select sala into v_sala from public.checklist_pasos where id = p_paso and tipo = v.tipo and activo;
  if not found then raise exception 'Ese paso no es de esta limpieza.'; end if;
  if not public._presente(p_id) then raise exception 'Scan the QR when you arrive (or tap "I''m here") first.'; end if;
  perform public._tomar_sala(p_id, v_sala);
  update public.limpiezas
     set checklist = case when p_hecho then checklist || jsonb_build_object(p_paso::text, now())
                          else checklist - p_paso::text end
   where id = p_id;
  perform public._revisar_sala(p_id, v_sala);
end $$;

-- Foto de cierre: la de cada sala la hace quien la lleva (la de la basura, cualquiera)
create or replace function public.registrar_foto(p_id uuid, p_sala text, p_ruta text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  v := public._mi_limpieza(p_id);
  if v.estado <> 'en_curso' then raise exception 'Primero hay que empezar la limpieza.'; end if;
  if v.linens_revisado is null then raise exception 'Check the linens bag first.'; end if;
  if p_sala not in ('bedroom', 'bathroom', 'kitchen', 'living', 'basura') then raise exception 'Sala no válida.'; end if;
  if split_part(p_ruta, '/', 1) <> p_id::text then raise exception 'La foto no es de esta limpieza.'; end if;
  perform public._tomar_sala(p_id, p_sala);
  insert into public.fotos_cierre (limpieza_id, sala, ruta, subida_por)
  values (p_id, p_sala, p_ruta, (select auth.uid()))
  on conflict (limpieza_id, sala) do update set ruta = excluded.ruta, subida_en = now(), subida_por = excluded.subida_por;
end $$;

-- 5. Nuevo para el equipo ----------------------------------------------------------------------
-- Llegar al apartamento ya empezado por un compañero: con el QR (o sin él: "I'm here")
create or replace function public.llegar_limpieza(p_id uuid, p_qr text default null,
  p_lat double precision default null, p_lng double precision default null, p_prec double precision default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas; v_token text; v_cod text; n int;
begin
  v := public._mi_limpieza(p_id);
  if v.estado <> 'en_curso' then raise exception 'This cleaning has not started yet: scan the QR to start it.'; end if;
  select qr_token, codigo into v_token, v_cod from public.propiedades where id = v.propiedad_id;
  if p_qr is not null and coalesce(regexp_replace(btrim(p_qr), '^OPSFLOW:', ''), '') <> v_token then
    raise exception 'This QR is not for %.', v_cod;
  end if;
  insert into public.limpieza_personas (limpieza_id, perfil_id, llegada_qr, gps)
  values (p_id, (select auth.uid()), p_qr is not null, public._gps(v.propiedad_id, p_lat, p_lng, p_prec))
  on conflict (limpieza_id, perfil_id) do nothing;
  select count(*) into n from public.limpieza_personas where limpieza_id = p_id;
  update public.limpiezas set personas = greatest(personas, least(n, 4)) where id = p_id;
  perform public._evento('llegó ' || (select nombre from public.perfiles where id = (select auth.uid()))
                         || case when p_qr is null then ' (sin QR)' else ' (QR)' end, p_id, null);
end $$;

-- Soltar una sala: quien la lleva (si no la ha terminado) o la líder de limpieza / Operación
create or replace function public.soltar_sala(p_id uuid, p_sala text)
returns void language plpgsql security definer set search_path = ''
as $$
declare s public.limpieza_salas;
begin
  select * into s from public.limpieza_salas where limpieza_id = p_id and sala = p_sala for update;
  if not found then raise exception 'Nobody has that room.'; end if;
  if not public._lider_limpieza() then
    perform public._mi_limpieza(p_id);
    if s.perfil_id is distinct from (select auth.uid()) then raise exception 'Only who has the room (or the leader) can release it.'; end if;
    if s.terminada_en is not null then raise exception 'That room is finished: ask your leader.'; end if;
  end if;
  delete from public.limpieza_salas where limpieza_id = p_id and sala = p_sala;
  perform public._evento('sala soltada: ' || p_sala || ' (era de ' || (select nombre from public.perfiles where id = s.perfil_id) || ')', p_id, null);
end $$;

-- Equipos activos (pantalla de Asignar)
create or replace function public.equipos_activos()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public._lider_limpieza() then raise exception 'Solo la líder de limpieza u Operación.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'responsable', e.responsable, 'nombre', public._equipo_txt(e.responsable),
      'miembros', (select jsonb_agg(jsonb_build_object('id', p.id, 'nombre', p.nombre) order by (p.id = e.responsable) desc, p.nombre)
                   from public.equipo_miembros m join public.perfiles p on p.id = m.perfil_id where m.equipo_id = e.id and m.hasta is null),
      'desde', e.creado_en) order by public._equipo_txt(e.responsable))
    from public.equipos e where e.activo), '[]'::jsonb);
end $$;

-- Formar un equipo (2–3 cleaners). Quien ya estaba en otro equipo sale de él. Lo que aún no ha empezado pasa al equipo.
create or replace function public.guardar_equipo(p_miembros uuid[])
returns uuid language plpgsql security definer set search_path = ''
as $$
declare v_id uuid; v_viejos uuid[]; e record;
begin
  if not public._lider_limpieza() then raise exception 'Solo la líder de limpieza u Operación forman equipos.'; end if;
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

-- Deshacer un equipo: cada uno vuelve a ir solo; lo que no ha empezado se queda con el responsable
create or replace function public.deshacer_equipo(p_equipo uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_nom text; v_m uuid[];
begin
  if not public._lider_limpieza() then raise exception 'Solo la líder de limpieza u Operación.'; end if;
  select public._equipo_txt(responsable) into v_nom from public.equipos where id = p_equipo and activo;
  if v_nom is null then raise exception 'Ese equipo no existe o ya se deshizo.'; end if;
  v_m := array(select perfil_id from public.equipo_miembros where equipo_id = p_equipo and hasta is null);
  update public.equipo_miembros set hasta = now() where equipo_id = p_equipo and hasta is null;
  update public.equipos set activo = false, deshecho_en = now() where id = p_equipo;
  perform public._reajustar(v_m);
  insert into public.eventos (quien, que) values ((select auth.uid()), 'equipo deshecho: ' || v_nom);
end $$;

-- Checklist (cleaner del equipo o líder): + salas con su dueño, quién llegó y si yo llegué
create or replace function public.mi_checklist(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  select * into v from public.limpiezas where id = p_id;
  if not found or public.mi_nivel() is null
     or not (public._lider_limpieza() or (public._soy_miembro(p_id) and v.publicada)) then
    raise exception 'Esta limpieza no es tuya.';
  end if;
  return jsonb_build_object(
    'inicio_qr', v.inicio_qr, 'fin_qr', v.fin_qr, 'linens_revisado', v.linens_revisado, 'cierre', v.cierre, 'personas', v.personas, 'estado', v.estado,
    'pasos', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'sala', p.sala, 'en', p.texto_en, 'es', p.texto_es,
                          'obligatorio', p.obligatorio, 'hecho', v.checklist ? p.id::text) order by p.orden)
                       from public.checklist_pasos p where p.tipo = v.tipo and p.activo), '[]'::jsonb),
    'fotos', coalesce((select jsonb_object_agg(f.sala, f.ruta) from public.fotos_cierre f where f.limpieza_id = p_id), '{}'::jsonb),
    'salas', coalesce((select jsonb_object_agg(s.sala, jsonb_build_object('nombre', split_part(pf.nombre, ' ', 1), 'mio', s.perfil_id = (select auth.uid()),
                          'desde', s.desde, 'terminada', s.terminada_en is not null))
                       from public.limpieza_salas s join public.perfiles pf on pf.id = s.perfil_id where s.limpieza_id = p_id), '{}'::jsonb),
    'equipo', (select jsonb_agg(jsonb_build_object('nombre', pf.nombre, 'yo', pf.id = (select auth.uid()),
                  'llegada', to_char(lp.llegada_en at time zone 'Europe/Malta', 'HH24:MI'), 'qr', lp.llegada_qr)
                  order by lp.llegada_en nulls last, pf.nombre)
               from public.perfiles pf left join public.limpieza_personas lp on lp.limpieza_id = p_id and lp.perfil_id = pf.id
               where pf.id = any(public._miembros_de(p_id))),
    'presente', public._presente(p_id));
end $$;

-- Seguimiento (líder de limpieza / Operación): equipo, quién llegó y quién lleva cada sala, por limpieza del día
create or replace function public.salas_dia(p_fecha date)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public._lider_limpieza() then raise exception 'Solo la líder de limpieza u Operación.'; end if;
  return coalesce((select jsonb_object_agg(l.id, jsonb_build_object(
      'equipo', public._equipo_limpieza_txt(l.id),
      'n', cardinality(public._miembros_de(l.id)),
      'llegadas', (select jsonb_agg(jsonb_build_object('nombre', split_part(pf.nombre, ' ', 1), 'en', to_char(lp.llegada_en at time zone 'Europe/Malta', 'HH24:MI'), 'qr', lp.llegada_qr) order by lp.llegada_en)
                   from public.limpieza_personas lp join public.perfiles pf on pf.id = lp.perfil_id where lp.limpieza_id = l.id),
      'salas', (select jsonb_agg(jsonb_build_object('sala', s.sala, 'nombre', split_part(pf.nombre, ' ', 1), 'desde', s.desde, 'terminada_en', s.terminada_en)
                   order by s.desde)
                from public.limpieza_salas s join public.perfiles pf on pf.id = s.perfil_id where s.limpieza_id = l.id)))
    from public.limpiezas l where l.fecha = p_fecha and l.asignada_a is not null), '{}'::jsonb);
end $$;

-- Tiempos por sala (líder de limpieza / Operación): media de minutos de cada sala en cada apartamento
create or replace function public.tiempos_salas(p_dias int default 90)
returns table (codigo text, nombre text, sala text, veces bigint, media_min int)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public._lider_limpieza() then raise exception 'Solo el líder de limpieza u Operación.'; end if;
  return query
  select p.codigo, p.nombre, s.sala, count(*), round(avg(extract(epoch from (s.terminada_en - s.desde)) / 60))::int
  from public.limpieza_salas s join public.limpiezas l on l.id = s.limpieza_id join public.propiedades p on p.id = l.propiedad_id
  where s.terminada_en is not null and l.fecha >= (now() at time zone 'Europe/Malta')::date - p_dias
    and s.terminada_en - s.desde between interval '2 minutes' and interval '4 hours'
  group by p.codigo, p.nombre, s.sala
  order by p.codigo, s.sala;
end $$;

-- 6. Pantallas que muestran el nombre del equipo ------------------------------------------------
-- Día del cleaner: lo de su equipo, con quién va y si ya llegó
create or replace function public.mi_dia(p_fecha date)
returns jsonb language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by (x->>'orden')::int nulls last), '[]'::jsonb) from (
    select jsonb_build_object(
      'id', l.id, 'orden', l.orden,
      'con', (select string_agg(split_part(pf.nombre, ' ', 1), ', ' order by pf.nombre) from public.perfiles pf
              where pf.id = any(public._miembros_de(l.id)) and pf.id <> (select auth.uid())),
      'presente', public._presente(l.id), 'tipo', l.tipo, 'estado', l.estado, 'motivo', l.motivo_no_entrar, 'linens_revisado', l.linens_revisado,
      'bolsa', (select jsonb_build_object('estado', b.estado, 'entregada_en', to_char(b.entregada_en at time zone 'Europe/Malta', 'HH24:MI'), 'comentario', b.comentario) from public.bolsas b where b.limpieza_id = l.id),
      'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo, 'direccion', p.direccion, 'mapa', p.mapa_url,
      'camas_dobles', p.camas_dobles, 'camas_indiv', p.camas_indiv, 'sofas', p.sofas_cama, 'banos', p.banos, 'notas', p.notas,
      'salida', to_char(c.hora_salida, 'HH24:MI'), 'entrada', to_char(c.hora_entrada, 'HH24:MI'),
      'pendientes', coalesce((select jsonb_agg(jsonb_build_object('id', pe.id, 'tipo', pe.tipo, 'detalle', pe.detalle,
                     'cantidad', pe.cantidad, 'estado', pe.estado, 'items', pe.items,
                     'listo_a', to_char(pe.listo_a at time zone 'Europe/Malta', 'HH24:MI'), 'listo_creado', case when pe.listo_a is not null then pe.creado_en end) order by pe.creado_en)
                     from public.pendientes pe where pe.limpieza_id = l.id), '[]'::jsonb)) x
    from public.limpiezas l
    join public.propiedades p on p.id = l.propiedad_id
    join public.checkouts c on c.id = l.checkout_id
    where l.fecha = p_fecha and l.publicada and public._soy_miembro(l.id) and l.estado::text <> 'cancelada'
      and public.mi_nivel() is not null
  ) t
$$;

create or replace function public.mi_ruta(p_fecha date)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_zona public.zona := public.mi_zona();
begin
  if not (public.mi_nivel() = 'operador' and public.mi_departamento() = 'Drivers') then
    raise exception 'Esta pantalla es para drivers.';
  end if;
  return jsonb_build_object(
    'tareas', coalesce((select jsonb_agg(jsonb_build_object(
        'id', pe.id, 'tipo', pe.tipo, 'detalle', pe.detalle, 'cantidad', pe.cantidad, 'estado', pe.estado,
        'prioritario', pe.prioritario, 'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo,
        'direccion', p.direccion, 'mapa', p.mapa_url, 'entrada', to_char(c.hora_entrada, 'HH24:MI'), 'foto', pe.foto, 'items', pe.items, 'incidencia', pe.incidencia)
        order by pe.prioritario desc, c.hora_entrada nulls last, pe.creado_en)
      from public.pendientes pe
      join public.limpiezas l on l.id = pe.limpieza_id
      join public.propiedades p on p.id = pe.propiedad_id
      join public.checkouts c on c.id = l.checkout_id
      where pe.fecha = p_fecha and pe.zona = v_zona
        and ((pe.tipo::text in ('linens', 'utiles') and pe.estado = 'preparado') or (pe.tipo = 'recogida' and pe.estado = 'abierto'))), '[]'::jsonb),
    'orden', coalesce((select jsonb_agg(jsonb_build_object(
        'cleaner', public._equipo_limpieza_txt(l.id), 'orden', l.orden, 'estado', l.estado, 'codigo', p.codigo, 'nombre', p.nombre,
        'pueblo', p.pueblo, 'mapa', p.mapa_url, 'entrada', to_char(c.hora_entrada, 'HH24:MI'))
        order by public._equipo_limpieza_txt(l.id), l.orden)
      from public.limpiezas l
      join public.propiedades p on p.id = l.propiedad_id
      join public.checkouts c on c.id = l.checkout_id
      where l.fecha = p_fecha and l.zona = v_zona and l.publicada and l.estado::text <> 'cancelada'), '[]'::jsonb));
end $$;

create or replace function public.entradas_dia(p_fecha date)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
begin
  if not (public._lider_limpieza() or (public.mi_nivel() = 'lider' and public.mi_departamento() = 'Drivers')) then
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

create or replace function public.tablero_zonas()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_hoy date := (now() at time zone 'Europe/Malta')::date;
begin
  if not public._es_driver() then raise exception 'Esta pantalla es para drivers.'; end if;
  return coalesce((select jsonb_agg(x order by x->>'zona', (x->>'prioridad')::int desc, x->>'entrada' nulls last, x->>'desde') from (
    select jsonb_build_object(
      'id', pe.id, 'zona', pe.zona, 'tipo', pe.tipo, 'detalle', pe.detalle, 'cantidad', pe.cantidad, 'items', pe.items,
      'foto', pe.foto, 'incidencia', pe.incidencia, 'fecha', pe.fecha,
      'desde', coalesce(pe.preparado_en, pe.creado_en),
      'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo, 'direccion', p.direccion, 'mapa', p.mapa_url,
      'entrada', case when c.fecha = v_hoy then to_char(c.hora_entrada, 'HH24:MI') end,
      'prioridad', case when c.fecha = v_hoy and c.hora_entrada is not null then 1 else 0 end,
      'tomado_por', t.nombre, 'equipo', public._equipo_limpieza_txt(l.id),
      'listo_a', to_char(pe.listo_a at time zone 'Europe/Malta', 'HH24:MI'), 'terminada', l.estado = 'terminada',
      'lat', case when p.coord_estado = 'confirmada' then p.lat end, 'lng', case when p.coord_estado = 'confirmada' then p.lng end, 'coord', p.coord_estado, 'mio', pe.tomado_por = (select auth.uid()), 'asignado', pe.asignado_por is not null) as x
    from public.pendientes pe
    join public.propiedades p on p.id = pe.propiedad_id
    join public.limpiezas l on l.id = pe.limpieza_id
    join public.checkouts c on c.id = l.checkout_id
    left join public.perfiles t on t.id = pe.tomado_por
    where public._en_driver(pe) and pe.fecha >= v_hoy - 7) s), '[]'::jsonb);
end $$;

-- Avisos: lo que era para "su cleaner" ahora es para cada miembro del equipo
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
      from public.perfiles p where p.activo and p.nivel = 'lider' and p.departamento = 'Drivers'
        and (p.zona is null or p.zona = pe.zona);

    elsif pe.tipo = 'linens' and pe.estado = 'abierto' then
      -- 2. Cleaner reporta linens → lider de linens
      insert into _dest select p.id, p.idioma,
        'Linens: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'es') end, 'Linens: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'en') end,
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        './?v=linens', null
      from public.perfiles p where p.activo and p.nivel = 'lider' and p.departamento = 'Linens'
        and (p.zona is null or p.zona = pe.zona);

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
        and ((p.nivel = 'operador' and p.zona = pe.zona) or (p.nivel = 'lider' and (p.zona is null or p.zona = pe.zona)));

    elsif pe.tipo::text = 'utiles' and pe.estado = 'abierto' then
      -- 8. Faltan utiles → lider de bodega
      insert into _dest select p.id, p.idioma,
        'Útiles: ' || pe.detalle, 'Tools: ' || pe.detalle,
        pr.codigo || ' · ' || pr.pueblo, pr.codigo || ' · ' || pr.pueblo,
        './?v=bodega', null
      from public.perfiles p where p.activo and p.nivel = 'lider' and p.departamento = 'Bodega'
        and (p.zona is null or p.zona = pe.zona);

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
      from public.perfiles p where p.activo and p.nivel = 'lider' and p.departamento = 'Limpieza'
        and (p.zona is null or p.zona = pe.zona);
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
      where p.activo and p.nivel = 'lider' and p.departamento in ('Limpieza', 'Drivers') and (p.zona is null or p.zona = li.zona);
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
      case when p.nivel = 'lider' and p.departamento = 'Limpieza' then './?v=seguimiento' else './' end, null
    from public.perfiles p
    where p.activo and (
         (p.nivel = 'lider' and p.departamento in ('Limpieza', 'Drivers') and (p.zona is null or p.zona = li.zona))
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

-- 7. Permisos -------------------------------------------------------------------------------------
revoke execute on function public.llegar_limpieza(uuid, text, double precision, double precision, double precision), public.soltar_sala(uuid, text),
  public.equipos_activos(), public.guardar_equipo(uuid[]), public.deshacer_equipo(uuid), public.salas_dia(date), public.tiempos_salas(int) from public, anon;
grant  execute on function public.llegar_limpieza(uuid, text, double precision, double precision, double precision), public.soltar_sala(uuid, text),
  public.equipos_activos(), public.guardar_equipo(uuid[]), public.deshacer_equipo(uuid), public.salas_dia(date), public.tiempos_salas(int) to authenticated;
revoke execute on function public.avisos_para(text, uuid, date) from public, anon, authenticated;
grant  execute on function public.avisos_para(text, uuid, date) to service_role;
