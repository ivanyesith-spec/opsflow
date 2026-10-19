-- OpsFlow · limpieza guiada v3: cierre del apartamento (9 oct 2026)
-- QR al entrar Y al salir · 3 preguntas de cierre (utiles, basura, llaves) · departamento Bodega.
-- Ejecutar DESPUES de 010. Se puede ejecutar varias veces.
-- Todo UPDATE/DELETE lleva WHERE (Supabase los bloquea si no).

-- 1. Departamento Bodega y pendiente de utiles ------------------------------
alter type public.tipo_pendiente add value if not exists 'utiles';
-- (en este archivo el valor nuevo se compara como texto: tipo::text = 'utiles')

do $$ declare c text; begin
  for c in select conname from pg_constraint
           where conrelid = 'public.perfiles'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%departamento%'
  loop execute format('alter table public.perfiles drop constraint %I', c); end loop;
end $$;
alter table public.perfiles add constraint perfiles_departamento_check
  check (departamento in ('Limpieza', 'Linens', 'Drivers', 'Bodega', 'Operación'));

-- Lider de bodega: ve los pendientes de utiles; drivers: tambien los utiles preparados de su zona
drop policy if exists "pendientes: lectura por rol" on public.pendientes;
create policy "pendientes: lectura por rol" on public.pendientes for select to authenticated using (
  (select public.mi_nivel()) = 'operacion'
  or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) = 'Limpieza')
  or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) = 'Linens' and tipo::text = 'linens')
  or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) = 'Bodega' and tipo::text = 'utiles')
  or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) = 'Drivers' and tipo::text in ('linens', 'recogida', 'utiles'))
  or ((select public.mi_nivel()) = 'operador' and (select public.mi_departamento()) = 'Limpieza'
       and limpieza_id in (select id from public.limpiezas where asignada_a = (select auth.uid())))
  or ((select public.mi_nivel()) = 'operador' and (select public.mi_departamento()) = 'Drivers'
       and zona = (select public.mi_zona())
       and (tipo::text = 'recogida' or (tipo::text in ('linens', 'utiles') and estado <> 'abierto')))
);

-- 2. Datos del cierre ----------------------------------------------------------
alter table public.limpiezas  add column if not exists fin_qr boolean;   -- true: termino escaneando el QR · false: "Can't scan"
alter table public.limpiezas  add column if not exists cierre jsonb;     -- {escoba, squeegee, recogedor, basura, llaves, motivo_llaves}
alter table public.pendientes add column if not exists foto text;        -- foto de la basura (ruta en fotos-cierre)

-- La foto de la basura se guarda como una sala mas ("basura")
do $$ declare c text; begin
  for c in select conname from pg_constraint
           where conrelid = 'public.fotos_cierre'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%sala%'
  loop execute format('alter table public.fotos_cierre drop constraint %I', c); end loop;
end $$;
alter table public.fotos_cierre add constraint fotos_cierre_sala_check
  check (sala in ('bedroom', 'bathroom', 'kitchen', 'living', 'basura'));

-- 3. Quien ve las fotos: ademas, la foto de la basura la ven el lider de drivers y los drivers de esa zona
create or replace function public._puede_ver_foto(p_nombre text)
returns boolean language sql stable security definer set search_path = ''
as $$
  select public._lider_limpieza()
  or exists (
    select 1 from public.limpiezas l
    where l.id::text = split_part(p_nombre, '/', 1) and l.asignada_a = (select auth.uid()) and public.mi_nivel() is not null)
  or (split_part(p_nombre, '/', 2) = 'basura.jpg' and public.mi_departamento() = 'Drivers' and exists (
    select 1 from public.limpiezas l
    where l.id::text = split_part(p_nombre, '/', 1)
      and (public.mi_nivel() = 'lider' or l.zona = public.mi_zona())))
$$;
revoke execute on function public._puede_ver_foto(text) from public, anon;
grant  execute on function public._puede_ver_foto(text) to authenticated;
drop policy if exists "fotos: lectura" on public.fotos_cierre;
create policy "fotos: lectura" on public.fotos_cierre
  for select to authenticated using (public._puede_ver_foto(ruta));

-- 4. Cerrar el apartamento: 3 preguntas + QR, todo de una vez -------------------
-- p_qr: lo leido en la pegatina; null = "Can't scan" (termina igual, marcado salida sin QR)
create or replace function public.cerrar_limpieza(
  p_id uuid, p_qr text, p_escoba boolean, p_squeegee boolean, p_recogedor boolean,
  p_basura boolean, p_llaves boolean, p_motivo_llaves text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v public.limpiezas; v_faltan int; v_fotos int; v_prop public.propiedades; v_prio boolean;
  v_utiles text[] := '{}'; v_ids uuid[] := '{}'; v_id uuid; v_foto text;
begin
  v := public._mi_limpieza(p_id);
  if v.estado <> 'en_curso' then raise exception 'Primero hay que empezar la limpieza.'; end if;
  select count(*) into v_faltan from public.checklist_pasos p
   where p.tipo = v.tipo and p.activo and p.obligatorio and not (v.checklist ? p.id::text);
  if v_faltan > 0 then raise exception 'Checklist not finished: % step(s) left.', v_faltan; end if;
  select count(distinct sala) into v_fotos from public.fotos_cierre
   where limpieza_id = p_id and sala in ('bedroom', 'bathroom', 'kitchen', 'living');
  if v_fotos < 4 then raise exception 'Take the 4 photos first (% of 4).', v_fotos; end if;
  if p_escoba is null or p_squeegee is null or p_recogedor is null or p_basura is null or p_llaves is null then
    raise exception 'Answer the 3 closing questions first.';
  end if;
  if p_basura then
    select ruta into v_foto from public.fotos_cierre where limpieza_id = p_id and sala = 'basura';
    if v_foto is null then raise exception 'Take a photo of the trash first.'; end if;
  end if;
  if not p_llaves and length(btrim(coalesce(p_motivo_llaves, ''))) < 3 then
    raise exception 'Write why the keys are not in the key box.';
  end if;
  select * into v_prop from public.propiedades where id = v.propiedad_id;
  if p_qr is not null and btrim(p_qr) <> 'OPSFLOW:' || v_prop.qr_token then
    raise exception 'This QR is not for %. Scan the sticker inside this apartment.', v_prop.codigo;
  end if;

  select (hora_entrada is not null) into v_prio from public.checkouts where id = v.checkout_id;
  if not p_escoba    then v_utiles := v_utiles || 'escoba'::text; end if;
  if not p_squeegee  then v_utiles := v_utiles || 'squeegee'::text; end if;
  if not p_recogedor then v_utiles := v_utiles || 'recogedor'::text; end if;
  if cardinality(v_utiles) > 0 then
    insert into public.pendientes (limpieza_id, propiedad_id, zona, fecha, tipo, detalle, cantidad, prioritario, creado_por, es_prueba)
    values (v.id, v.propiedad_id, v.zona, v.fecha, 'utiles'::text::public.tipo_pendiente,
            'Falta: ' || array_to_string(v_utiles, ', '), cardinality(v_utiles), coalesce(v_prio, false), (select auth.uid()), v.es_prueba)
    returning id into v_id;
    v_ids := v_ids || v_id;
    perform public._evento('cierre: faltan útiles', v.id, v_id);
  end if;
  if p_basura then
    insert into public.pendientes (limpieza_id, propiedad_id, zona, fecha, tipo, detalle, cantidad, prioritario, creado_por, es_prueba, foto)
    values (v.id, v.propiedad_id, v.zona, v.fecha, 'recogida', 'Basura dejada en el apto', 1, coalesce(v_prio, false),
            (select auth.uid()), v.es_prueba, v_foto)
    returning id into v_id;
    v_ids := v_ids || v_id;
    perform public._evento('cierre: basura en el apto', v.id, v_id);
  end if;

  update public.limpiezas set estado = 'terminada', fin = now(), fin_qr = (p_qr is not null),
    cierre = jsonb_build_object('escoba', p_escoba, 'squeegee', p_squeegee, 'recogedor', p_recogedor,
                                'basura', p_basura, 'llaves', p_llaves,
                                'motivo_llaves', case when p_llaves then null else left(btrim(p_motivo_llaves), 200) end)
  where id = p_id;
  perform public._evento('limpieza terminada' || case when p_qr is null then ' (salida sin QR)' else '' end
                         || case when p_llaves then '' else ' · llaves NO en key box' end, p_id, null);
  return jsonb_build_object('pendientes', to_jsonb(v_ids), 'llaves', p_llaves);
end $$;

-- El Finish antiguo ya no cierra: obliga a pasar por el cierre (si alguien tiene la app vieja, se lo dice)
create or replace function public.terminar_limpieza(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  raise exception 'Update the app: close the apartment and scan the QR to finish. · Actualiza la app.';
end $$;

-- 5. Funciones que cambian (utiles, bodega, foto de basura, QR de salida, avisos) -----
create or replace function public.registrar_foto(p_id uuid, p_sala text, p_ruta text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  v := public._mi_limpieza(p_id);
  if v.estado <> 'en_curso' then raise exception 'Primero hay que empezar la limpieza.'; end if;
  if p_sala not in ('bedroom', 'bathroom', 'kitchen', 'living', 'basura') then raise exception 'Sala no válida.'; end if;
  if split_part(p_ruta, '/', 1) <> p_id::text then raise exception 'La foto no es de esta limpieza.'; end if;
  insert into public.fotos_cierre (limpieza_id, sala, ruta, subida_por)
  values (p_id, p_sala, p_ruta, (select auth.uid()))
  on conflict (limpieza_id, sala) do update set ruta = excluded.ruta, subida_en = now(), subida_por = excluded.subida_por;
end $$;

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
        'direccion', p.direccion, 'mapa', p.mapa_url, 'entrada', to_char(c.hora_entrada, 'HH24:MI'), 'foto', pe.foto)
        order by pe.prioritario desc, pe.creado_en)
      from public.pendientes pe
      join public.limpiezas l on l.id = pe.limpieza_id
      join public.propiedades p on p.id = pe.propiedad_id
      join public.checkouts c on c.id = l.checkout_id
      where pe.fecha = p_fecha and pe.zona = v_zona
        and ((pe.tipo::text in ('linens', 'utiles') and pe.estado = 'preparado') or (pe.tipo = 'recogida' and pe.estado = 'abierto'))), '[]'::jsonb),
    'orden', coalesce((select jsonb_agg(jsonb_build_object(
        'cleaner', pf.nombre, 'orden', l.orden, 'estado', l.estado, 'codigo', p.codigo, 'nombre', p.nombre,
        'pueblo', p.pueblo, 'mapa', p.mapa_url, 'entrada', to_char(c.hora_entrada, 'HH24:MI'))
        order by pf.nombre, l.orden)
      from public.limpiezas l
      join public.propiedades p on p.id = l.propiedad_id
      join public.checkouts c on c.id = l.checkout_id
      join public.perfiles pf on pf.id = l.asignada_a
      where l.fecha = p_fecha and l.zona = v_zona and l.publicada), '[]'::jsonb));
end $$;

create or replace function public.marcar_preparado(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.pendientes;
begin
  select * into v from public.pendientes where id = p_id for update;
  if not found or v.tipo::text not in ('linens', 'utiles') then raise exception 'Ese pendiente no se prepara.'; end if;
  -- Linens lo prepara linens; los utiles (escoba, squeegee, recogedor) los prepara bodega
  if not (public.mi_nivel() = 'operacion'
          or (public.mi_nivel() = 'lider' and public.mi_departamento() = case when v.tipo::text = 'utiles' then 'Bodega' else 'Linens' end)) then
    raise exception 'Solo % u Operación marcan preparado.', case when v.tipo::text = 'utiles' then 'bodega' else 'linens' end;
  end if;
  if v.estado <> 'abierto' then raise exception 'Ese pendiente ya está preparado.'; end if;
  update public.pendientes set estado = 'preparado', preparado_por = (select auth.uid()), preparado_en = now() where id = p_id;
  perform public._evento('preparado por ' || case when v.tipo::text = 'utiles' then 'bodega' else 'linens' end, v.limpieza_id, p_id);
end $$;

create or replace function public.marcar_entregado(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.pendientes;
begin
  select * into v from public.pendientes where id = p_id for update;
  if not found then raise exception 'Ese pendiente no existe.'; end if;
  if not (public.mi_nivel() = 'operacion'
          or (public.mi_nivel() = 'lider' and public.mi_departamento() = 'Drivers')
          or (public.mi_nivel() = 'operador' and public.mi_departamento() = 'Drivers' and public.mi_zona() = v.zona)) then
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

create or replace function public.tablero(p_fecha date)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
begin
  if public.mi_nivel() is distinct from 'operacion' then raise exception 'El tablero es de Operación.'; end if;
  return jsonb_build_object(
    'limpiezas', (select coalesce(jsonb_object_agg(estado, n), '{}'::jsonb)
                  from (select estado, count(*) n from public.limpiezas where fecha = p_fecha group by estado) a),
    'sin_publicar', (select count(*) from public.limpiezas where fecha = p_fecha and asignada_a is not null and not publicada),
    'en_linens',   (select count(*) from public.pendientes where fecha = p_fecha and tipo = 'linens' and estado = 'abierto'),
    'en_bodega',   (select count(*) from public.pendientes where fecha = p_fecha and tipo::text = 'utiles' and estado = 'abierto'),
    'en_driver',   (select count(*) from public.pendientes where fecha = p_fecha and ((tipo::text in ('linens', 'utiles') and estado = 'preparado') or (tipo = 'recogida' and estado = 'abierto'))),
    'llaves_no',   (select coalesce(jsonb_agg(jsonb_build_object('codigo', p.codigo, 'nombre', p.nombre, 'motivo', l.cierre->>'motivo_llaves')), '[]'::jsonb)
                    from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id
                    where l.fecha = p_fecha and l.cierre->>'llaves' = 'false'),
    'por_recibir', (select count(*) from public.pendientes where fecha = p_fecha and tipo = 'linens' and estado = 'entregado'),
    'otros_abiertos', (select count(*) from public.pendientes where fecha = p_fecha and tipo = 'otro' and estado = 'abierto'),
    'cerrados',    (select count(*) from public.pendientes where fecha = p_fecha and estado = 'cerrado'),
    'minutos_cierre', (select round(avg(extract(epoch from cerrado_en - creado_en)) / 60)
                       from public.pendientes where fecha = p_fecha and estado = 'cerrado'),
    'no_pude_entrar', (select coalesce(jsonb_agg(jsonb_build_object('codigo', p.codigo, 'nombre', p.nombre, 'motivo', l.motivo_no_entrar)), '[]'::jsonb)
                       from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id
                       where l.fecha = p_fecha and l.estado = 'no_pude_entrar'));
end $$;

create or replace function public.mi_checklist(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  select * into v from public.limpiezas where id = p_id;
  if not found or public.mi_nivel() is null
     or not (public._lider_limpieza() or (v.asignada_a = (select auth.uid()) and v.publicada)) then
    raise exception 'Esta limpieza no es tuya.';
  end if;
  return jsonb_build_object(
    'inicio_qr', v.inicio_qr, 'fin_qr', v.fin_qr, 'cierre', v.cierre, 'personas', v.personas, 'estado', v.estado,
    'pasos', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'sala', p.sala, 'en', p.texto_en, 'es', p.texto_es,
                          'obligatorio', p.obligatorio, 'hecho', v.checklist ? p.id::text) order by p.orden)
                       from public.checklist_pasos p where p.tipo = v.tipo and p.activo), '[]'::jsonb),
    'fotos', coalesce((select jsonb_object_agg(f.sala, f.ruta) from public.fotos_cierre f where f.limpieza_id = p_id), '{}'::jsonb));
end $$;

create or replace function public.tiempos_aptos(p_dias int default 90)
returns table (codigo text, nombre text, tipo text, limpiezas bigint, media_min int, mediana_min int, ultima date)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public._lider_limpieza() then raise exception 'Solo el líder de limpieza u Operación.'; end if;
  return query
  select p.codigo, p.nombre, l.tipo::text, count(*),
         round(avg(extract(epoch from (l.fin - l.inicio)) / 60))::int,
         round(percentile_cont(0.5) within group (order by extract(epoch from (l.fin - l.inicio)) / 60))::int,
         max(l.fecha)
  from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id
  where l.estado = 'terminada' and l.inicio_qr and l.fin_qr and l.fin is not null and l.inicio is not null
    and l.fecha >= current_date - p_dias
    and l.fin - l.inicio between interval '10 minutes' and interval '6 hours'
  group by p.codigo, p.nombre, l.tipo
  order by p.codigo, l.tipo::text;
end $$;

create or replace function public.tiempos_personas(p_dias int default 90)
returns table (cleaner text, tipo text, limpiezas bigint, media_min int, sin_qr bigint)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if public.mi_nivel() is distinct from 'operacion' then raise exception 'Solo Operación.'; end if;
  return query
  select pf.nombre, l.tipo::text,
         count(*) filter (where l.inicio_qr and l.fin_qr and l.fin - l.inicio between interval '10 minutes' and interval '6 hours'),
         round(avg(extract(epoch from (l.fin - l.inicio)) / 60)
               filter (where l.inicio_qr and l.fin_qr and l.fin - l.inicio between interval '10 minutes' and interval '6 hours'))::int,
         count(*) filter (where l.inicio_qr is false or l.fin_qr is false)
  from public.limpiezas l join public.perfiles pf on pf.id = l.asignada_a
  where l.estado = 'terminada' and l.fecha >= current_date - p_dias
  group by pf.nombre, l.tipo
  order by pf.nombre, l.tipo::text;
end $$;

-- Avisos: utiles → bodega → drivers; basura → drivers + lider de drivers; llaves → lideres
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

    if pe.tipo = 'linens' and pe.estado = 'abierto' then
      -- 2. Cleaner reporta linens → lider de linens
      insert into _dest select p.id, p.idioma,
        'Linens: ' || pe.cantidad || ' × ' || pe.detalle, 'Linens: ' || pe.cantidad || ' × ' || pe.detalle,
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        './?v=linens', null
      from public.perfiles p where p.activo and p.nivel = 'lider' and p.departamento = 'Linens'
        and (p.zona is null or p.zona = pe.zona);

    elsif pe.tipo = 'linens' and pe.estado = 'preparado' then
      -- 3. Linens preparado → drivers de la zona
      insert into _dest select p.id, p.idioma,
        'Entregar: ' || pe.cantidad || ' × ' || pe.detalle, 'Deliver: ' || pe.cantidad || ' × ' || pe.detalle,
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Guest arrives ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
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
        'Entregado: ' || pe.cantidad || ' × ' || pe.detalle, 'Delivered: ' || pe.cantidad || ' × ' || pe.detalle,
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
    from public.limpiezas l join public.perfiles p on p.id = l.asignada_a
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

-- 6. Permisos -------------------------------------------------------------------
revoke execute on function public.cerrar_limpieza(uuid, text, boolean, boolean, boolean, boolean, boolean, text) from public, anon;
grant  execute on function public.cerrar_limpieza(uuid, text, boolean, boolean, boolean, boolean, boolean, text) to authenticated;
revoke execute on function public.avisos_para(text, uuid, date) from public, anon, authenticated;
grant  execute on function public.avisos_para(text, uuid, date) to service_role;
