-- OpsFlow · pruebas de ubicaciones (coordenadas de cada apartamento)
-- Ejecutar DESPUES de 025. Supabase → SQL Editor → pegar todo → Run. Todas las filas deben decir OK.
-- Crea usuarios y apartamentos de prueba y lo deja todo como estaba.

-- Por si una ejecución anterior se cortó a medias
delete from public.pendientes where propiedad_id in (select id from public.propiedades where codigo like 'TEST-UB_');
delete from public.checkouts  where propiedad_id in (select id from public.propiedades where codigo like 'TEST-UB_');
delete from public.propiedades where codigo like 'TEST-UB_';
delete from public.perfiles where id::text like '00000000-0000-0000-0000-0000000009%';
delete from auth.users      where id::text like '00000000-0000-0000-0000-0000000009%';

create temp table resultados (n int, prueba text, resultado text);
create temp table _inicio as select coalesce((select max(id) from public.eventos), 0) as max_ev,
                                    coalesce((select max(id) from public.avisos_enviados), 0) as max_av;

create function pg_temp.como(uid text) returns void language plpgsql as $$
begin
  perform set_config('role', 'none', true);
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
create function pg_temp.yo() returns void language plpgsql as $$
begin perform set_config('role', 'none', true); end $$;
create function pg_temp.falla(q text) returns boolean language plpgsql as $$
begin execute q; return false; exception when others then return true; end $$;
create function pg_temp.ok(n int, prueba text, cond boolean, detalle text default '') returns void language plpgsql as $$
begin
  perform set_config('role', 'none', true);
  insert into resultados values (n, prueba, case when coalesce(cond, false) then 'OK' else 'FALLO ' || coalesce(detalle, '') end);
end $$;
create function pg_temp.pid(c text) returns uuid language sql as $$ select id from public.propiedades where codigo = c $$;
create function pg_temp.est(c text) returns text language sql as $$
  select coord_estado || '/' || coalesce(coord_fuente, '-') from public.propiedades where codigo = c $$;
-- Simula escaneos con el GPS del teléfono sobre la limpieza del apto (como hacen iniciar/cerrar)
create function pg_temp.escanear(c text, k text, la double precision, ln double precision, prec double precision) returns void language plpgsql as $$
begin
  update public.limpiezas l set gps = coalesce(l.gps, '{}'::jsonb) || jsonb_build_object(k, public._gps(l.propiedad_id, la, ln, prec))
  where l.propiedad_id = pg_temp.pid(c) and l.fecha = current_date;
end $$;

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-0000-0000-000000000901', 'ub.cleaner@opsflow.test', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-000000000902', 'ub.driver@opsflow.test',  'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-000000000903', 'ub.lidlimp@opsflow.test', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-000000000904', 'ub.operacion@opsflow.test','authenticated', 'authenticated');
insert into public.perfiles (id, nombre, departamento, nivel, zona, idioma) values
  ('00000000-0000-0000-0000-000000000901', 'UB Cleaner',   'Limpieza',  'operador',  'Norte', 'en'),
  ('00000000-0000-0000-0000-000000000902', 'UB Driver',    'Drivers',   'operador',  'Norte', 'en'),
  ('00000000-0000-0000-0000-000000000903', 'UB LidLimp',   'Limpieza',  'lider',     null,    'es'),
  ('00000000-0000-0000-0000-000000000904', 'UB Operacion', 'Operación', 'operacion', null,    'es');
-- UB1–UB4 sin coordenada; UB5 con un punto escrito a mano; UB6 desactivada
insert into public.propiedades (codigo, nombre, zona, pueblo, direccion, es_prueba, lat, lng, activa) values
  ('TEST-UB1', 'Prueba ubicación 1', 'Norte', 'Ubiville', 'Triq il-Prova 1', true, null, null, true),
  ('TEST-UB2', 'Prueba ubicación 2', 'Norte', 'Ubiville', 'Triq il-Prova 2', true, null, null, true),
  ('TEST-UB3', 'Prueba ubicación 3', 'Norte', 'Ubiville', 'Triq il-Prova 3', true, null, null, true),
  ('TEST-UB4', 'Prueba ubicación 4', 'Sur',   'Ubiville', 'Triq il-Prova 4', true, null, null, true),
  ('TEST-UB5', 'Prueba ubicación 5', 'Norte', 'Ubiville', 'Triq il-Prova 5', true, 35.9500, 14.4000, true),
  ('TEST-UB6', 'Prueba ubicación 6', 'Norte', 'Ubiville', 'Triq il-Prova 6', true, null, null, false);

do $$
declare
  CL text := '00000000-0000-0000-0000-000000000901';
  DR text := '00000000-0000-0000-0000-000000000902';
  LL text := '00000000-0000-0000-0000-000000000903';
  OP text := '00000000-0000-0000-0000-000000000904';
  F  date := current_date;
  l3 uuid; q3 text; c int; e boolean; r text; j jsonb; p public.propiedades;
begin
  perform pg_temp.como(OP);
  perform public.cargar_checkouts(F, E'TEST-UB1 10:00\nTEST-UB2 10:00\nTEST-UB3 10:00\nTEST-UB4 10:00\nTEST-UB5 10:00', true);
  perform pg_temp.yo();

  -- 1. Nadie del campo ni los líderes tocan las ubicaciones; buscar y guardar es solo del servidor
  perform pg_temp.como(CL);
  e := (select count(*) = 0 from public.propiedades where codigo like 'TEST-UB_')
       and pg_temp.falla($q$select public.ubicacion_confirmar(pg_temp.pid('TEST-UB5'))$q$);
  perform pg_temp.como(DR);
  e := e and (select count(*) = 0 from public.propiedades where codigo like 'TEST-UB_')
         and pg_temp.falla($q$select public.ubicacion_guardar(pg_temp.pid('TEST-UB1'), 35.95, 14.40, 'tomtom', false, null)$q$);
  perform pg_temp.como(LL);
  e := e and pg_temp.falla($q$select public.ubicacion_confirmar(pg_temp.pid('TEST-UB5'))$q$)
         and pg_temp.falla($q$select public.ubicacion_escaneos(pg_temp.pid('TEST-UB5'))$q$);
  perform pg_temp.como(OP);
  e := e and pg_temp.falla('select * from public.ubicaciones_para_buscar(null)')
         and pg_temp.falla($q$select public.ubicacion_guardar(pg_temp.pid('TEST-UB1'), 35.95, 14.40, 'tomtom', false, null)$q$);
  perform pg_temp.ok(1, 'Cleaner y driver no ven; los líderes no confirman; buscar y guardar solo el servidor', e);

  -- 2. El estado no se puede escribir a mano (ni siquiera Operación desde la tabla)
  perform pg_temp.como(OP);
  update public.propiedades set coord_estado = 'confirmada', coord_fuente = 'enlace' where codigo = 'TEST-UB5';
  perform pg_temp.yo();
  perform pg_temp.ok(2, 'El estado no se escribe directamente: el punto a mano sigue "propuesta"', pg_temp.est('TEST-UB5') = 'propuesta/manual', pg_temp.est('TEST-UB5'));

  -- 3. Qué busca el botón: sin marcar → activas sin coordenada; marcadas → las no confirmadas
  select count(*) into c from public.ubicaciones_para_buscar(null) where codigo like 'TEST-UB_';
  select string_agg(codigo, ',' order by codigo) into r from public.ubicaciones_para_buscar(array[pg_temp.pid('TEST-UB5'), pg_temp.pid('TEST-UB6')]);
  perform pg_temp.ok(3, 'Buscar: sin marcar = activas sin coordenada (4); marcadas = las indicadas', c = 4 and r = 'TEST-UB5,TEST-UB6', c || ' ' || r);

  -- 4. Guardar lo de TomTom: bueno → propuesta; dudoso → dudosa con motivo; fuera de Malta → dudosa
  r := public.ubicacion_guardar(pg_temp.pid('TEST-UB1'), 35.9531, 14.4201, 'tomtom', false, null, '{"tipo":"Point Address"}', 'Ubiville');
  r := r || ' ' || public.ubicacion_guardar(pg_temp.pid('TEST-UB2'), 35.9600, 14.4100, 'tomtom', true, 'TomTom solo encontró la calle, no el portal');
  r := r || ' ' || public.ubicacion_guardar(pg_temp.pid('TEST-UB4'), 41.3900, 2.1700, 'enlace', false, null);
  select coord_motivo into j from (select to_jsonb(coord_motivo) coord_motivo from public.propiedades where codigo = 'TEST-UB2') x;
  perform pg_temp.ok(4, 'TomTom bueno → propuesta; solo calle → dudosa con motivo; fuera de Malta → dudosa',
    r = 'propuesta dudosa dudosa' and j #>> '{}' like 'TomTom solo encontró la calle%'
      and (select coord_motivo from public.propiedades where codigo = 'TEST-UB4') = 'Fuera de Malta y Gozo', r || ' ' || j::text);

  -- 5. Dos fuentes a más de 150 m → dudosa, guardando el punto anterior
  r := public.ubicacion_guardar(pg_temp.pid('TEST-UB5'), 35.9536, 14.4000, 'tomtom', false, null);
  select * into p from public.propiedades where codigo = 'TEST-UB5';
  perform pg_temp.ok(5, 'Punto a mano y TomTom a ~400 m → dudosa (guarda el anterior)',
    r = 'dudosa' and p.coord_motivo like '%400 m%' and (p.coord_info->'anterior'->>'lat')::numeric = 35.95, coalesce(p.coord_motivo, '') || ' ' || coalesce(p.coord_info::text, ''));

  -- 6. Solo Operación confirma; una confirmada no se pisa y ya no sale para buscar
  perform pg_temp.como(OP);
  perform public.ubicacion_confirmar(pg_temp.pid('TEST-UB1'));
  e := pg_temp.falla($q$select public.ubicacion_confirmar(pg_temp.pid('TEST-UB3'))$q$);   -- UB3 no tiene punto
  perform pg_temp.yo();
  r := public.ubicacion_guardar(pg_temp.pid('TEST-UB1'), 35.9900, 14.3500, 'tomtom', false, null);
  select * into p from public.propiedades where codigo = 'TEST-UB1';
  c := (select count(*) from public.ubicaciones_para_buscar(array[pg_temp.pid('TEST-UB1')]));
  perform pg_temp.ok(6, 'Confirma Operación (queda quién y cuándo); no se pisa ni se vuelve a buscar; sin punto no se confirma',
    e and r = 'confirmada' and p.coord_estado = 'confirmada' and p.lat = 35.9531 and p.coord_confirmada_por = OP::uuid
      and p.coord_confirmada_en is not null and c = 0, r || ' ' || p.lat || ' ' || c);

  -- 7. GPS de la limpieza: solo mide contra coordenadas confirmadas
  perform pg_temp.escanear('TEST-UB1', 'inicio', 35.9532, 14.4201, 10);   -- confirmada: ~11 m
  perform pg_temp.escanear('TEST-UB2', 'inicio', 35.9600, 14.4100, 10);   -- dudosa: no mide
  select (gps->'inicio'->>'dist')::int into c from public.limpiezas where propiedad_id = pg_temp.pid('TEST-UB1') and fecha = F;
  select gps->'inicio'->>'dist' into r from public.limpiezas where propiedad_id = pg_temp.pid('TEST-UB2') and fecha = F;
  perform pg_temp.ok(7, 'El GPS de la limpieza ignora las coordenadas no confirmadas', c between 5 and 20 and r is null, c || ' / ' || coalesce(r, 'null'));

  -- 8. Sin coordenada: el primer escaneo con buena precisión la propone (flujo real con QR); con mala precisión no
  perform pg_temp.como(LL);
  select l.id into l3 from public.limpiezas l where l.propiedad_id = pg_temp.pid('TEST-UB3') and l.fecha = F;
  perform public.asignar_limpieza(l3, CL::uuid, 1, 'normal');
  perform public.publicar_orden(F);
  perform pg_temp.yo();
  select 'OPSFLOW:' || qr_token into q3 from public.propiedades where codigo = 'TEST-UB3';
  perform pg_temp.escanear('TEST-UB3', 'prueba', 35.9700, 14.4300, 60);    -- 60 m de precisión: no vale
  r := pg_temp.est('TEST-UB3');
  perform pg_temp.como(CL);
  perform public.iniciar_con_qr(l3, q3, 35.9710, 14.4310, 12);
  perform pg_temp.yo();
  select * into p from public.propiedades where codigo = 'TEST-UB3';
  perform pg_temp.ok(8, 'Sin coordenada: escaneo con precisión ≤ 30 m la propone (GPS); con 60 m no',
    r = 'sin/-' and p.coord_estado = 'propuesta' and p.coord_fuente = 'gps' and p.lat = 35.971, r || ' → ' || pg_temp.est('TEST-UB3'));

  -- 9. Propuesta de otra fuente y un escaneo a más de 150 m → dudosa
  perform public.ubicacion_guardar(pg_temp.pid('TEST-UB4'), 35.8800, 14.5000, 'tomtom', false, null);   -- sustituye el punto de Barcelona
  -- (el anterior estaba fuera de Malta → la distancia es enorme → dudosa: se corrige escribiendo a mano)
  perform pg_temp.como(OP);
  update public.propiedades set lat = 35.8801, lng = 14.5000 where codigo = 'TEST-UB4';
  perform pg_temp.yo();
  r := pg_temp.est('TEST-UB4');
  perform pg_temp.escanear('TEST-UB4', 'inicio', 35.8830, 14.5000, 8);    -- ~330 m
  select * into p from public.propiedades where codigo = 'TEST-UB4';
  perform pg_temp.ok(9, 'Punto a mano → propuesta; un escaneo a ~330 m lo pasa a dudosa',
    r = 'propuesta/manual' and p.coord_estado = 'dudosa' and p.coord_motivo like 'El GPS de un escaneo cae a 3__ m%', r || ' → ' || p.coord_estado || ' ' || coalesce(p.coord_motivo, ''));

  -- 10. Confirmada: mientras la media de los escaneos sea ≤ 100 m sigue igual; si pasa de 100 m → dudosa
  perform pg_temp.escanear('TEST-UB1', 'a', 35.9540, 14.4201, 10);   -- ~100 m
  perform pg_temp.escanear('TEST-UB1', 'b', 35.9540, 14.4201, 10);
  r := pg_temp.est('TEST-UB1');
  perform pg_temp.escanear('TEST-UB1', 'c', 35.9580, 14.4201, 10);   -- ~545 m
  select * into p from public.propiedades where codigo = 'TEST-UB1';
  perform pg_temp.ok(10, 'Confirmada: escaneos a ≤ 100 m de media no la tocan; a más de 100 m pasa a dudosa',
    r = 'confirmada/tomtom' and p.coord_estado = 'dudosa' and p.coord_motivo like 'El GPS de 4 escaneos cae a % m de media'
      and p.coord_confirmada_en is null, r || ' → ' || p.coord_estado || ' ' || coalesce(p.coord_motivo, ''));

  -- 11. Cambiar la dirección de una confirmada la devuelve a propuesta
  perform pg_temp.como(OP);
  perform public.ubicacion_confirmar(pg_temp.pid('TEST-UB3'));
  update public.propiedades set direccion = 'Triq il-Prova 33' where codigo = 'TEST-UB3';
  perform pg_temp.yo();
  select * into p from public.propiedades where codigo = 'TEST-UB3';
  perform pg_temp.ok(11, 'Cambiar la dirección de una confirmada → propuesta, con aviso',
    p.coord_estado = 'propuesta' and p.coord_motivo = 'La dirección cambió: revisa el punto' and p.coord_confirmada_en is null, pg_temp.est('TEST-UB3'));

  -- 12. Tráfico: el pueblo "como lo escribe TomTom" solo cuenta si la coordenada está confirmada
  perform set_config('opsflow.coord', '1', true);
  update public.propiedades set pueblo_tomtom = 'San Prova il-Baħar' where codigo in ('TEST-UB3', 'TEST-UB5');
  perform set_config('opsflow.coord', '', true);
  r := public._zona_de_pueblo('San Prova il-Baħar');
  perform pg_temp.como(OP);
  perform public.ubicacion_confirmar(pg_temp.pid('TEST-UB5'));
  perform pg_temp.yo();
  r := r || ' ' || public._zona_de_pueblo('San Prova il-Baħar');
  perform pg_temp.ok(12, 'Tráfico: el pueblo de TomTom solo cuenta con la coordenada confirmada', r = 'General Norte', r);

  -- 13. Ficha: resumen de escaneos (solo Operación) y todo queda en el historial de la propiedad
  perform pg_temp.como(OP);
  j := public.ubicacion_escaneos(pg_temp.pid('TEST-UB1'));
  perform pg_temp.yo();
  c := (select count(*) from public.eventos e where e.id > (select max_ev from _inicio) and e.propiedad_id = pg_temp.pid('TEST-UB1'));
  perform pg_temp.ok(13, 'Ficha: escaneos y distancia media; cada cambio queda en el historial',
    (j->>'n')::int = 4 and (j->>'media_m')::int > 100 and c >= 3, j::text || ' eventos=' || c);
end $$;

-- Dejarlo todo como estaba
delete from public.pendientes where propiedad_id in (select id from public.propiedades where codigo like 'TEST-UB_');
delete from public.checkouts  where propiedad_id in (select id from public.propiedades where codigo like 'TEST-UB_');
delete from public.propiedades where codigo like 'TEST-UB_';
delete from public.avisos_enviados where id > (select max_av from _inicio);
delete from public.eventos where id > (select max_ev from _inicio);
delete from public.perfiles where id::text like '00000000-0000-0000-0000-0000000009%';
delete from auth.users      where id::text like '00000000-0000-0000-0000-0000000009%';

select * from resultados order by n;
