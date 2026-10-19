-- OpsFlow · pruebas de la revisión de linens y el reporte único (limpieza guiada v4)
-- Ejecutar DESPUES de 015. Supabase → SQL Editor → pegar todo → Run.
-- Crea usuarios y apartamentos de prueba, lo deja todo como estaba y muestra una tabla: todas las filas deben decir OK.

-- Por si una ejecución anterior se cortó a medias
delete from public.pendientes where propiedad_id in (select id from public.propiedades where codigo like 'TEST-LN_');
delete from public.checkouts  where propiedad_id in (select id from public.propiedades where codigo like 'TEST-LN_');
delete from public.propiedades where codigo like 'TEST-LN_';
delete from public.perfiles where id::text like '00000000-0000-0000-0000-0000000000e%';
delete from auth.users      where id::text like '00000000-0000-0000-0000-0000000000e%';

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
  ('00000000-0000-0000-0000-0000000000e1', 'ln.cleanera@opsflow.test', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000e2', 'ln.cleanerb@opsflow.test', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000e3', 'ln.lidlin@opsflow.test',   'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000e4', 'ln.drvnorte@opsflow.test', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000e5', 'ln.lidlimp@opsflow.test',  'authenticated', 'authenticated');
insert into public.perfiles (id, nombre, departamento, nivel, zona, idioma) values
  ('00000000-0000-0000-0000-0000000000e1', 'LN Cleaner A', 'Limpieza', 'operador', 'Norte', 'en'),
  ('00000000-0000-0000-0000-0000000000e2', 'LN Cleaner B', 'Limpieza', 'operador', 'Norte', 'en'),
  ('00000000-0000-0000-0000-0000000000e3', 'LN LidLinens', 'Linens',   'lider',    null,    'es'),
  ('00000000-0000-0000-0000-0000000000e4', 'LN DrvNorte',  'Drivers',  'operador', 'Norte', 'en'),
  ('00000000-0000-0000-0000-0000000000e5', 'LN LidLimp',   'Limpieza', 'lider',    null,    'es');
insert into public.propiedades (codigo, nombre, zona, pueblo, es_prueba) values
  ('TEST-LN1', 'Prueba linens 1', 'Norte', 'Prueba', true),
  ('TEST-LN2', 'Prueba linens 2', 'Norte', 'Prueba', true);

do $$
declare
  A  text := '00000000-0000-0000-0000-0000000000e1';
  B  text := '00000000-0000-0000-0000-0000000000e2';
  LN text := '00000000-0000-0000-0000-0000000000e3';
  DN text := '00000000-0000-0000-0000-0000000000e4';
  LL text := '00000000-0000-0000-0000-0000000000e5';
  F  date := '2099-04-01';
  l1 uuid; l2 uuid; q1 text; q2 text; p1 uuid; p2 uuid; paso int;
  c int; e boolean; r text; j jsonb; t timestamptz;
begin
  perform pg_temp.como(LL);
  perform public.cargar_checkouts(F, E'TEST-LN1 10:00 15:00\nTEST-LN2 10:00', true);
  perform pg_temp.yo();
  select l.id into l1 from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id where l.fecha = F and p.codigo = 'TEST-LN1';
  select l.id into l2 from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id where l.fecha = F and p.codigo = 'TEST-LN2';
  select 'OPSFLOW:' || qr_token into q1 from public.propiedades where codigo = 'TEST-LN1';
  select 'OPSFLOW:' || qr_token into q2 from public.propiedades where codigo = 'TEST-LN2';
  select min(id) into paso from public.checklist_pasos where tipo = 'normal' and obligatorio;
  perform pg_temp.como(LL);
  perform public.asignar_limpieza(l1, A::uuid, 1, 'normal');
  perform public.asignar_limpieza(l2, A::uuid, 2, 'normal');
  perform public.publicar_orden(F);
  perform pg_temp.como(A);
  perform public.iniciar_con_qr(l1, q1);
  perform public.iniciar_con_qr(l2, q2);

  -- 1. Sin revisar la bolsa: ni pasos, ni fotos, ni cierre
  perform pg_temp.como(A);
  r := pg_temp.error(format('select public.marcar_paso(%L, %s, true)', l1, paso));
  e := pg_temp.falla(format('select public.registrar_foto(%L, %L, %L)', l1, 'bedroom', l1 || '/bedroom.jpg'))
   and pg_temp.falla(format('select public.cerrar_limpieza(%L, %L, true, true, true, false, true)', l1, q1));
  perform pg_temp.ok(1, 'Sin revisar linens: no se marcan pasos, ni fotos, ni se cierra', r like 'Check the linens bag first%' and e, r);

  -- 2. El reporte rechaza listas vacías, artículos inventados, cantidades malas y repetidos
  perform pg_temp.como(A);
  e := pg_temp.falla(format('select public.reportar_linens(%L, %L)', l1, '[]'))
   and pg_temp.falla(format('select public.reportar_linens(%L, %L)', l1, '[{"item":"cortina","cantidad":1}]'))
   and pg_temp.falla(format('select public.reportar_linens(%L, %L)', l1, '[{"item":"esponja","cantidad":0}]'))
   and pg_temp.falla(format('select public.reportar_linens(%L, %L)', l1, '[{"item":"esponja","cantidad":2.5}]'))
   and pg_temp.falla(format('select public.reportar_linens(%L, %L)', l1, '[{"item":"esponja","cantidad":"2"}]'))
   and pg_temp.falla(format('select public.reportar_linens(%L, %L)', l1, '[{"item":"esponja","cantidad":1},{"item":"esponja","cantidad":1}]'))
   and pg_temp.falla(format('select public.reportar_linens(%L, %L)', l1, '[{"item":"esponja","cantidad":1},{"item":"cortina","cantidad":1}]'))
   and pg_temp.falla(format('select public.reportar_linens(%L, %L)', l1, '[{"item":"esponja","cantidad":1},{"item":"toalla_grande","cantidad":0}]'))
   and pg_temp.falla(format('select public.reportar_linens(%L, %L)', l1, '[{"item":"esponja","cantidad":1},{"item":"toalla_grande","cantidad":51}]'));
  perform pg_temp.yo();
  perform pg_temp.ok(2, 'Reporte: rechaza vacío, artículos inventados, cantidades malas y repetidos',
    e and not exists (select 1 from public.pendientes where limpieza_id = l1), '');

  -- 3. Otro cleaner no reporta ni revisa una limpieza ajena
  perform pg_temp.como(B);
  e := pg_temp.falla(format('select public.reportar_linens(%L, %L)', l1, '[{"item":"esponja","cantidad":1}]'))
   and pg_temp.falla(format('select public.linens_ok(%L)', l1));
  perform pg_temp.ok(3, 'Otro cleaner no reporta ni revisa una limpieza ajena', e);

  -- 4. Reporte único con 3 artículos = 1 pendiente; desbloquea la checklist
  perform pg_temp.como(A);
  p1 := public.reportar_linens(l1, '[{"item":"sabana_doble","cantidad":2},{"item":"toalla_grande","cantidad":1},{"item":"papel_higienico","cantidad":3}]');
  perform public.marcar_paso(l1, paso, true);
  perform pg_temp.yo();
  select linens_revisado into t from public.limpiezas where id = l1;
  perform pg_temp.ok(4, 'Reporte único: 3 artículos en 1 pendiente (prioritario por check-in) y se abre la checklist',
    (select count(*) = 1 from public.pendientes where limpieza_id = l1)
    and (select tipo = 'linens' and cantidad = 6 and prioritario and jsonb_array_length(items) = 3
                and detalle = '2 × Sábana doble · 1 × Toalla grande · 3 × Papel higiénico' from public.pendientes where id = p1)
    and t is not null and (select checklist ? paso::text from public.limpiezas where id = l1),
    (select detalle from public.pendientes where id = p1));

  -- 5. Después puede añadir otro reporte; la hora de revisión no cambia
  perform pg_temp.como(A);
  p2 := public.reportar_linens(l1, '[{"item":"funda_duvet_sencilla","cantidad":1}]');
  perform pg_temp.yo();
  perform pg_temp.ok(5, 'Durante la limpieza se puede añadir otro reporte',
    (select count(*) = 2 from public.pendientes where limpieza_id = l1) and (select linens_revisado = t from public.limpiezas where id = l1));

  -- 6. "Nothing missing": revisa sin crear pedido
  perform pg_temp.como(A);
  perform public.linens_ok(l2);
  perform public.marcar_paso(l2, paso, true);
  perform pg_temp.yo();
  perform pg_temp.ok(6, '"Nothing missing" desbloquea sin crear pedido',
    (select linens_revisado is not null from public.limpiezas where id = l2) and not exists (select 1 from public.pendientes where limpieza_id = l2));

  -- 7. Aviso único al líder de linens, en su idioma; al driver, en el suyo
  perform pg_temp.yo();
  select string_agg(a.titulo, ' | ') into r from public.avisos_para('pendiente', p1) a where a.perfil_id = LN::uuid;
  perform pg_temp.ok(7, 'Un solo aviso a linens con todo el pedido',
    r = '⚠ Linens: 2 × Sábana doble · 1 × Toalla grande · 3 × Papel higiénico', r);

  -- 8. Cadena: linens prepara una vez → driver ve la lista → entrega → cleaner recibe
  perform pg_temp.como(LN);
  perform public.marcar_preparado(p1);
  perform pg_temp.yo();
  select string_agg(a.titulo, ' | ') into r from public.avisos_para('pendiente', p1) a where a.perfil_id = DN::uuid;
  perform pg_temp.como(DN);
  select t2 into j from jsonb_array_elements(public.mi_ruta(F)->'tareas') t2 where t2->>'id' = p1::text;
  perform public.marcar_entregado(p1);
  perform pg_temp.como(A);
  c := (select count(*) from jsonb_array_elements(public.mi_dia(F)) d, jsonb_array_elements(d->'pendientes') pe
        where pe->>'id' = p1::text and jsonb_array_length(pe->'items') = 3);
  perform public.marcar_recibido(p1);
  perform pg_temp.yo();
  perform pg_temp.ok(8, 'Pedido completo: preparado, entregado y recibido una sola vez; driver y cleaner ven la lista',
    jsonb_array_length(j->'items') = 3 and c = 1 and r = '⚠ Deliver: 2 × Double sheet · 1 × Large towel · 3 × Toilet paper'
    and (select estado = 'cerrado' from public.pendientes where id = p1), coalesce(r, '-') || ' / ' || coalesce(j::text, '-'));

  -- 9. La checklist dice si ya revisó (para la app)
  perform pg_temp.como(A);
  j := public.mi_checklist(l2);
  perform pg_temp.ok(9, 'mi_checklist indica la revisión de linens', j->>'linens_revisado' is not null);

  -- 10. Ninguna funcion de OpsFlow tiene UPDATE/DELETE sin WHERE
  perform pg_temp.yo();
  select string_agg(distinct p.proname, ', ') into r
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace,
       lateral regexp_split_to_table(regexp_replace(lower(p.prosrc), '--[^\n]*', '', 'g'), ';') st
  where n.nspname = 'public' and p.prolang in (select oid from pg_language where lanname in ('plpgsql', 'sql'))
    and st ~ '(^|\s|\()(update\s+\S+\s+set|delete\s+from)\s' and st !~ '\swhere\s';
  perform pg_temp.ok(10, 'Ningún UPDATE/DELETE sin WHERE (Supabase los bloquea)', r is null, r);
end $$;

-- Dejarlo todo como estaba
delete from public.pendientes where propiedad_id in (select id from public.propiedades where codigo like 'TEST-LN_');
delete from public.checkouts  where propiedad_id in (select id from public.propiedades where codigo like 'TEST-LN_');
delete from public.propiedades where codigo like 'TEST-LN_';
delete from public.avisos_enviados where id > (select max_av from _inicio);
delete from public.eventos where id > (select max_ev from _inicio);
delete from public.perfiles where id::text like '00000000-0000-0000-0000-0000000000e%';
delete from auth.users      where id::text like '00000000-0000-0000-0000-0000000000e%';

select * from resultados order by n;
