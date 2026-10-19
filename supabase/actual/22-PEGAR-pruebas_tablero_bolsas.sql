-- OpsFlow · pruebas del tablero de zonas y las bolsas de linens con QR
-- Ejecutar DESPUES de 021. Supabase → SQL Editor → pegar todo → Run.
-- Crea usuarios y apartamentos de prueba, lo deja todo como estaba y muestra una tabla: todas las filas deben decir OK.

-- Por si una ejecución anterior se cortó a medias
select set_config('storage.allow_delete_query', 'true', false);  -- Supabase solo deja borrar fotos así si se pide expresamente
delete from storage.objects where bucket_id = 'fotos-cierre' and split_part(name, '/', 1) in
  (select l.id::text from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id where p.codigo like 'TEST-TB_');
delete from public.pendientes where propiedad_id in (select id from public.propiedades where codigo like 'TEST-TB_');
delete from public.checkouts  where propiedad_id in (select id from public.propiedades where codigo like 'TEST-TB_');
delete from public.propiedades where codigo like 'TEST-TB_';
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
create function pg_temp.error(q text) returns text language plpgsql as $$
begin execute q; return '(sin error)'; exception when others then return sqlerrm; end $$;
create function pg_temp.ok(n int, prueba text, cond boolean, detalle text default '') returns void language plpgsql as $$
begin
  perform set_config('role', 'none', true);
  insert into resultados values (n, prueba, case when coalesce(cond, false) then 'OK' else 'FALLO ' || coalesce(detalle, '') end);
end $$;

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-0000-0000-000000000901', 'tb.cleanera@opsflow.test', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-000000000902', 'tb.cleanerb@opsflow.test', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-000000000903', 'tb.lidlimp@opsflow.test',  'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-000000000904', 'tb.lidlin@opsflow.test',   'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-000000000905', 'tb.liddrv@opsflow.test',   'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-000000000906', 'tb.drvnorte@opsflow.test', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-000000000907', 'tb.drvsur@opsflow.test',   'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-000000000908', 'tb.operacion@opsflow.test','authenticated', 'authenticated');
insert into public.perfiles (id, nombre, departamento, nivel, zona, idioma) values
  ('00000000-0000-0000-0000-000000000901', 'TB Cleaner A',  'Limpieza',  'operador',  'Norte', 'en'),
  ('00000000-0000-0000-0000-000000000902', 'TB Cleaner B',  'Limpieza',  'operador',  'Norte', 'en'),
  ('00000000-0000-0000-0000-000000000903', 'TB LidLimp',    'Limpieza',  'lider',     null,    'es'),
  ('00000000-0000-0000-0000-000000000904', 'TB LidLinens',  'Linens',    'lider',     null,    'es'),
  ('00000000-0000-0000-0000-000000000905', 'TB LidDrivers', 'Drivers',   'lider',     null,    'es'),
  ('00000000-0000-0000-0000-000000000906', 'TB DrvNorte',   'Drivers',   'operador',  'Norte', 'en'),
  ('00000000-0000-0000-0000-000000000907', 'TB DrvSur',     'Drivers',   'operador',  'Sur',   'en'),
  ('00000000-0000-0000-0000-000000000908', 'TB Operacion',  'Operación', 'operacion', null,    'es');
insert into public.propiedades (codigo, nombre, zona, pueblo, es_prueba) values
  ('TEST-TB1', 'Prueba tablero 1', 'Norte', 'Prueba', true),
  ('TEST-TB2', 'Prueba tablero 2', 'Norte', 'Prueba', true),
  ('TEST-TB3', 'Prueba tablero 3', 'Norte', 'Prueba', true);

do $$
declare
  A  text := '00000000-0000-0000-0000-000000000901';
  B  text := '00000000-0000-0000-0000-000000000902';
  LL text := '00000000-0000-0000-0000-000000000903';
  LN text := '00000000-0000-0000-0000-000000000904';
  LD text := '00000000-0000-0000-0000-000000000905';
  DN text := '00000000-0000-0000-0000-000000000906';
  DS text := '00000000-0000-0000-0000-000000000907';
  OP text := '00000000-0000-0000-0000-000000000908';
  F  date := (now() at time zone 'Europe/Malta')::date;
  l1 uuid; l2 uuid; l3 uuid; p1 uuid; p2 uuid; b1 uuid; b3 uuid; qr1 text; qr3 text;
  c int; e boolean; r text; j jsonb;
begin
  -- TB1 sin check-in, TB2 con check-in hoy 15:00, TB3 se cancela
  perform pg_temp.como(OP);
  perform public.cargar_checkouts(F, E'TEST-TB1 10:00\nTEST-TB2 10:00 15:00\nTEST-TB3 11:00', true);
  perform pg_temp.yo();
  select l.id into l1 from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id where l.fecha = F and p.codigo = 'TEST-TB1';
  select l.id into l2 from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id where l.fecha = F and p.codigo = 'TEST-TB2';
  select l.id into l3 from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id where l.fecha = F and p.codigo = 'TEST-TB3';
  perform pg_temp.como(LL);
  perform public.asignar_limpieza(l1, A::uuid, 1, 'normal');
  perform public.asignar_limpieza(l2, A::uuid, 2, 'normal');
  perform public.asignar_limpieza(l3, B::uuid, 1, 'normal');
  perform public.publicar_orden(F);
  perform pg_temp.como(A);
  perform public.iniciar_limpieza(l1);
  perform public.iniciar_limpieza(l2);
  perform public.linens_ok(l1);
  perform public.linens_ok(l2);
  p1 := public.reportar_pendiente(l1, 'recogida', '', 1);
  perform pg_temp.yo();
  update public.pendientes set creado_en = now() - interval '3 hours' where id = p1;   -- lleva 3 h esperando
  perform pg_temp.como(A);
  p2 := public.reportar_pendiente(l2, 'recogida', '', 1);

  -- 1. Todos los drivers ven el tablero de todas las zonas; el cleaner no
  perform pg_temp.como(DS);
  j := public.tablero_zonas();
  c := (select count(*) from jsonb_array_elements(j) x where x->>'codigo' like 'TEST-TB%');
  perform pg_temp.como(A);
  e := pg_temp.falla('select public.tablero_zonas()');
  perform pg_temp.ok(1, 'Tablero: un driver de Sur ve lo pendiente de Norte; el cleaner no', e and c = 2, c::text);

  -- 2. Primero el check-in de hoy, aunque sea más reciente; se ve desde cuándo espera
  perform pg_temp.como(DN);
  select string_agg(x->>'codigo' || ':' || (x->>'prioridad') || ':' || coalesce(x->>'entrada', '-'), ' ' order by o) into r
    from jsonb_array_elements(public.tablero_zonas()) with ordinality t(x, o) where x->>'codigo' like 'TEST-TB%';
  j := (select x from jsonb_array_elements(public.tablero_zonas()) x where x->>'id' = p1::text);
  perform pg_temp.ok(2, 'Check-in de hoy arriba (aunque sea más nuevo); "desde" para marcar lo de más de 2 h',
    r = 'TEST-TB2:1:15:00 TEST-TB1:0:-' and (j->>'desde')::timestamptz < now() - interval '2 hours', r);

  -- 3. "I'll take it": el driver de Sur coge la de Norte; el de Norte ya no puede cogerla ni cerrarla
  perform pg_temp.como(DS);
  perform public.tomar_tarea(p1);
  perform pg_temp.como(DN);
  r := pg_temp.error(format('select public.tomar_tarea(%L)', p1));
  e := pg_temp.falla(format('select public.marcar_entregado(%L)', p1));
  j := (select x from jsonb_array_elements(public.tablero_zonas()) x where x->>'id' = p1::text);
  perform pg_temp.ok(3, 'Coger: los demás ven quién la lleva y no pueden cogerla ni cerrarla',
    r like 'TB DrvSur is already on it%' and e and j->>'tomado_por' = 'TB DrvSur' and not (j->>'mio')::boolean, r);

  -- 4. Soltar: solo quien la cogió (o el líder)
  perform pg_temp.como(DN);
  e := pg_temp.falla(format('select public.soltar_tarea(%L)', p1));
  perform pg_temp.como(DS);
  perform public.soltar_tarea(p1);
  perform pg_temp.yo();
  perform pg_temp.ok(4, 'Soltar: solo quien la cogió', e and (select tomado_por is null from public.pendientes where id = p1));

  -- 5. Cogida por otra zona → la puede cerrar; sin coger, otra zona no
  perform pg_temp.como(DS);
  e := pg_temp.falla(format('select public.marcar_entregado(%L)', p2));
  perform public.tomar_tarea(p2);
  perform public.marcar_entregado(p2);
  perform pg_temp.yo();
  perform pg_temp.ok(5, 'Sin cogerla, otra zona no la cierra; cogida, sí', e and (select estado = 'cerrado' from public.pendientes where id = p2));

  -- 6. El líder asigna (no un driver, ni a un cleaner) y le llega el aviso al driver
  perform pg_temp.como(DS);
  e := pg_temp.falla(format('select public.asignar_tarea(%L, %L)', p1, DN));
  perform pg_temp.como(LD);
  e := e and pg_temp.falla(format('select public.asignar_tarea(%L, %L)', p1, A));
  perform public.asignar_tarea(p1, DN::uuid);
  perform pg_temp.yo();
  select string_agg(pf.nombre || ': ' || a.titulo, ' | ') into r from public.avisos_para('pendiente', p1) a join public.perfiles pf on pf.id = a.perfil_id
   where pf.id::text like '00000000-0000-0000-0000-0000000009%';
  perform pg_temp.ok(6, 'Asignar: solo el líder, solo a drivers; aviso al driver',
    e and (select tomado_por = DN::uuid and asignado_por = LD::uuid from public.pendientes where id = p1) and r = 'TB DrvNorte: Assigned to you: TEST-TB1', r);

  -- 7. Bolsas del día: una por limpieza no cancelada; el cleaner no puede pedirlas
  perform pg_temp.como(LL);
  perform public.cancelar_limpieza(l3, 'Reserva cancelada');
  perform pg_temp.como(A);
  e := pg_temp.falla(format('select public.bolsas_dia(%L)', F));
  perform pg_temp.como(LN);
  j := public.bolsas_dia(F);
  perform pg_temp.yo();
  select id into b1 from public.bolsas where limpieza_id = l1;
  perform pg_temp.ok(7, 'Bolsas: una por limpieza (la cancelada no); el cleaner no las gestiona',
    e and (select count(*) from jsonb_array_elements(j) x where x->>'codigo' like 'TEST-TB%') = 2
      and not exists (select 1 from public.bolsas where limpieza_id = l3) and (j->0->>'codigo') = 'TEST-TB2', j::text);

  -- 8. El código de la etiqueta: solo linens lo imprime; nadie lo lee de la tabla
  perform pg_temp.como(DN);
  e := pg_temp.falla('select token from public.bolsas limit 1') and pg_temp.falla(format('select * from public.bolsas_etiquetas(%L)', F));
  c := (select count(*) from public.bolsas where id = b1);
  perform pg_temp.como(LN);
  select qr into qr1 from public.bolsas_etiquetas(F) where codigo = 'TEST-TB1';
  perform pg_temp.ok(8, 'Etiquetas QR: solo linens; el código no se lee de la tabla (pero el driver ve la bolsa)',
    e and c = 1 and qr1 like 'OPSFLOW-BAG:%');

  -- 9. Escanear: no antes de que linens la prepare; luego pasa al driver; otro driver no se la queda
  perform pg_temp.como(DN);
  r := pg_temp.error(format('select public.escanear_bolsa(%L)', qr1));
  e := pg_temp.falla(format('select public.preparar_bolsa(%L)', b1));
  perform pg_temp.como(LN);
  perform public.preparar_bolsa(b1);
  perform pg_temp.como(DN);
  j := public.escanear_bolsa(qr1);
  perform pg_temp.como(DS);
  r := r || ' / ' || pg_temp.error(format('select public.escanear_bolsa(%L)', qr1)) || ' / ' || pg_temp.error(format('select public.escanear_bolsa(%L)', 'OPSFLOW-BAG:falso'));
  perform pg_temp.como(DN);
  c := jsonb_array_length(public.mis_trabajos()->'bolsas');
  perform pg_temp.ok(9, 'Escanear: no sin preparar; pasa a la lista del driver; otro driver ni un código falso',
    e and r like 'Bag TEST-TB1 is not ready yet%' and r like '%Bag TEST-TB1 is already with TB DrvNorte%' and r like '%not an OpsFlow bag label%'
    and j->>'codigo' = 'TEST-TB1' and c = 1, r);

  -- 10. Foto de entrega: solo el driver que la lleva puede subirla; sin foto no se entrega
  perform pg_temp.como(DS);
  e := pg_temp.falla(format('insert into storage.objects (bucket_id, name) values (%L, %L)', 'fotos-cierre', l1 || '/bolsa.jpg'));
  perform pg_temp.como(DN);
  e := e and pg_temp.falla(format('insert into storage.objects (bucket_id, name) values (%L, %L)', 'fotos-cierre', l1 || '/bedroom.jpg'));
  r := pg_temp.error(format('select public.entregar_bolsa(%L, null, null)', b1));
  insert into storage.objects (bucket_id, name) values ('fotos-cierre', l1 || '/bolsa.jpg');
  perform public.entregar_bolsa(b1, l1 || '/bolsa.jpg', 'Left at the door, guest inside');
  perform pg_temp.yo();
  perform pg_temp.ok(10, 'Entregar: foto obligatoria (solo el que la lleva), con comentario',
    e and r like 'Take the delivery photo first%'
    and (select estado = 'entregada' and comentario = 'Left at the door, guest inside' from public.bolsas where id = b1)
    and exists (select 1 from public.fotos_cierre where limpieza_id = l1 and sala = 'bolsa'), r);

  -- 11. El cleaner ve su bolsa entregada; la foto la ven linens y el cleaner, no otro cleaner
  perform pg_temp.como(A);
  j := (select d->'bolsa' from jsonb_array_elements(public.mi_dia(F)) d where d->>'id' = l1::text);
  c := (select count(*) from storage.objects where name = l1 || '/bolsa.jpg');
  perform pg_temp.como(LN);
  c := c * 10 + (select count(*) from storage.objects where name = l1 || '/bolsa.jpg');
  perform pg_temp.como(B);
  c := c * 10 + (select count(*) from storage.objects where name = l1 || '/bolsa.jpg');
  perform pg_temp.ok(11, 'El cleaner ve "bolsa entregada"; la foto: cleaner y linens sí, otro cleaner no',
    j->>'estado' = 'entregada' and j->>'comentario' = 'Left at the door, guest inside' and c = 110, coalesce(j::text, '-') || ' / ' || c);

  -- 12. No pude entregar la bolsa: solo quien la lleva y con motivo
  perform pg_temp.yo();
  select id into b3 from public.bolsas where limpieza_id = l2;
  perform pg_temp.como(LN);
  perform public.preparar_bolsa(b3);
  select qr into qr3 from public.bolsas_etiquetas(F) where codigo = 'TEST-TB2';
  perform pg_temp.como(DN);
  perform public.escanear_bolsa(qr3);
  perform pg_temp.como(DS);
  e := pg_temp.falla(format('select public.no_pude_entregar_bolsa(%L, %L)', b3, 'No key'));
  perform pg_temp.como(DN);
  e := e and pg_temp.falla(format('select public.no_pude_entregar_bolsa(%L, %L)', b3, ''));
  perform public.no_pude_entregar_bolsa(b3, 'Nobody to open');
  perform pg_temp.yo();
  perform pg_temp.ok(12, '"No pude entregar" la bolsa: solo quien la lleva, con motivo',
    e and (select incidencia = 'Nobody to open' and estado = 'en_camion' from public.bolsas where id = b3));

  -- 13. La foto de la bolsa no cuenta como foto de cierre del cleaner
  perform pg_temp.como(A);
  perform public.marcar_paso(l1, p.id, true) from public.checklist_pasos p where p.tipo = 'normal' and p.obligatorio;
  perform public.registrar_foto(l1, s, l1 || '/' || s || '.jpg') from unnest(array['bedroom', 'bathroom', 'kitchen']) s;
  r := pg_temp.error(format('select public.cerrar_limpieza(%L, null, true, true, true, false, true)', l1));
  perform pg_temp.ok(13, 'La foto de la bolsa no cuenta como una de las 4 fotos de cierre', r like 'Take the 4 photos first (3 of 4)%', r);

  -- 14. Ninguna funcion de OpsFlow tiene UPDATE/DELETE sin WHERE
  perform pg_temp.yo();
  select string_agg(distinct p.proname, ', ') into r
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace,
       lateral regexp_split_to_table(regexp_replace(lower(p.prosrc), '--[^\n]*', '', 'g'), ';') st
  where n.nspname = 'public' and p.prolang in (select oid from pg_language where lanname in ('plpgsql', 'sql'))
    and st ~ '(^|\s|\()(update\s+\S+\s+set|delete\s+from)\s' and st !~ '\swhere\s';
  perform pg_temp.ok(14, 'Ningún UPDATE/DELETE sin WHERE (Supabase los bloquea)', r is null, r);
end $$;

-- Dejarlo todo como estaba
select set_config('storage.allow_delete_query', 'true', false);
delete from storage.objects where bucket_id = 'fotos-cierre' and split_part(name, '/', 1) in
  (select l.id::text from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id where p.codigo like 'TEST-TB_');
delete from public.pendientes where propiedad_id in (select id from public.propiedades where codigo like 'TEST-TB_');
delete from public.checkouts  where propiedad_id in (select id from public.propiedades where codigo like 'TEST-TB_');
delete from public.propiedades where codigo like 'TEST-TB_';
delete from public.avisos_enviados where id > (select max_av from _inicio);
delete from public.eventos where id > (select max_ev from _inicio);
delete from public.perfiles where id::text like '00000000-0000-0000-0000-0000000009%';
delete from auth.users      where id::text like '00000000-0000-0000-0000-0000000009%';

select * from resultados order by n;
