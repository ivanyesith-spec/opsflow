-- OpsFlow · pruebas de rutas: hora de entrada de los equipos, aviso "listo en 30 min", punto de bodega y rutas
-- Ejecutar DESPUES de 027. Supabase → SQL Editor → pegar todo → Run. Todas las filas deben decir OK.
-- Crea usuarios y apartamentos de prueba y lo deja todo como estaba (también el punto de bodega).

-- Por si una ejecución anterior se cortó a medias
delete from public.rutas_driver where driver::text like '00000000-0000-0000-0000-0000000010%';
delete from public.entradas_equipo where cleaner::text like '00000000-0000-0000-0000-0000000010%';
delete from public.pendientes where propiedad_id in (select id from public.propiedades where codigo like 'TEST-RT_');
delete from public.checkouts  where propiedad_id in (select id from public.propiedades where codigo like 'TEST-RT_');
delete from public.propiedades where codigo like 'TEST-RT_';
delete from public.perfiles where id::text like '00000000-0000-0000-0000-0000000010%';
delete from auth.users      where id::text like '00000000-0000-0000-0000-0000000010%';

create temp table resultados (n int, prueba text, resultado text);
create temp table _inicio as select coalesce((select max(id) from public.eventos), 0) as max_ev,
                                    coalesce((select max(id) from public.avisos_enviados), 0) as max_av;
create temp table _bodega as select * from public.puntos_base where clave = 'bodega';

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
create function pg_temp.lim(c text) returns uuid language sql as $$
  select l.id from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id
  where p.codigo = c and l.fecha = (now() at time zone 'Europe/Malta')::date $$;

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-0000-0000-000000001001', 'rt.cleanera@opsflow.test', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-000000001002', 'rt.cleanerb@opsflow.test', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-000000001003', 'rt.lidlimp@opsflow.test',  'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-000000001004', 'rt.lidlin@opsflow.test',   'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-000000001005', 'rt.liddrv@opsflow.test',   'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-000000001006', 'rt.drvnorte@opsflow.test', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-000000001007', 'rt.drvsur@opsflow.test',   'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-000000001008', 'rt.operacion@opsflow.test','authenticated', 'authenticated');
insert into public.perfiles (id, nombre, departamento, nivel, zona, idioma) values
  ('00000000-0000-0000-0000-000000001001', 'RT Cleaner A',  'Limpieza',  'operador',  'Norte', 'en'),
  ('00000000-0000-0000-0000-000000001002', 'RT Cleaner B',  'Limpieza',  'operador',  'Norte', 'en'),
  ('00000000-0000-0000-0000-000000001003', 'RT LidLimp',    'Limpieza',  'lider',     null,    'es'),
  ('00000000-0000-0000-0000-000000001004', 'RT LidLinens',  'Linens',    'lider',     null,    'es'),
  ('00000000-0000-0000-0000-000000001005', 'RT LidDrivers', 'Drivers',   'lider',     null,    'es'),
  ('00000000-0000-0000-0000-000000001006', 'RT DrvNorte',   'Drivers',   'operador',  'Norte', 'en'),
  ('00000000-0000-0000-0000-000000001007', 'RT DrvSur',     'Drivers',   'operador',  'Sur',   'en'),
  ('00000000-0000-0000-0000-000000001008', 'RT Operacion',  'Operación', 'operacion', null,    'es');
-- RT1 con punto confirmado (se confirma abajo), RT2 sin punto, RT3 de otro equipo
insert into public.propiedades (codigo, nombre, zona, pueblo, es_prueba, lat, lng) values
  ('TEST-RT1', 'Prueba ruta 1', 'Norte', 'Prueba', true, 35.9500, 14.4100),
  ('TEST-RT2', 'Prueba ruta 2', 'Norte', 'Prueba', true, null, null),
  ('TEST-RT3', 'Prueba ruta 3', 'Norte', 'Prueba', true, null, null);

do $$
declare
  A  text := '00000000-0000-0000-0000-000000001001';
  B  text := '00000000-0000-0000-0000-000000001002';
  LL text := '00000000-0000-0000-0000-000000001003';
  LN text := '00000000-0000-0000-0000-000000001004';
  LD text := '00000000-0000-0000-0000-000000001005';
  DN text := '00000000-0000-0000-0000-000000001006';
  DS text := '00000000-0000-0000-0000-000000001007';
  OP text := '00000000-0000-0000-0000-000000001008';
  F  date := (now() at time zone 'Europe/Malta')::date;
  l1 uuid; l2 uuid; l3 uuid; av uuid; b1 uuid; tok text; c int; e boolean; r text; j jsonb; x jsonb;
begin
  perform pg_temp.como(OP);
  perform public.cargar_checkouts(F, E'TEST-RT1 10:00 15:00\nTEST-RT2 10:00\nTEST-RT3 10:00', true);
  perform public.ubicacion_confirmar((select id from public.propiedades where codigo = 'TEST-RT1'));
  perform pg_temp.yo();
  l1 := pg_temp.lim('TEST-RT1'); l2 := pg_temp.lim('TEST-RT2'); l3 := pg_temp.lim('TEST-RT3');
  perform pg_temp.como(LL);
  perform public.asignar_limpieza(l1, A::uuid, 1, 'normal');
  perform public.asignar_limpieza(l2, A::uuid, 2, 'normal');
  perform public.asignar_limpieza(l3, B::uuid, 1, 'normal');
  perform public.publicar_orden(F);

  -- 1. Hora de entrada: 11:00 por defecto; solo la líder de limpieza / Operación la cambian; rango 05:00–20:00
  j := public.entradas_dia(F);
  r := (select string_agg(y->>'nombre' || '=' || (y->>'hora') || '/' || (y->>'fijada'), ' ' order by y->>'nombre') from jsonb_array_elements(j) y where y->>'nombre' like 'RT %');
  perform public.fijar_entrada(F, A::uuid, '09:30');
  e := pg_temp.falla(format('select public.fijar_entrada(%L, %L, %L)', F, A, '04:00'))
   and pg_temp.falla(format('select public.fijar_entrada(%L, %L, %L)', F - 1, A, '09:00'))
   and pg_temp.falla(format('select public.fijar_entrada(%L, %L, %L)', F, DN, '09:00'));
  perform pg_temp.como(A);
  e := e and pg_temp.falla(format('select public.fijar_entrada(%L, %L, %L)', F, A, '08:00'));
  perform pg_temp.como(DN);
  e := e and pg_temp.falla(format('select public.fijar_entrada(%L, %L, %L)', F, B, '08:00'))
         and pg_temp.falla(format('select public.entradas_dia(%L)', F));
  perform pg_temp.ok(1, 'Hora de entrada: 11:00 por defecto; la fija la líder (05:00–20:00, no días pasados); cleaner y driver no',
    e and r = 'RT Cleaner A=11:00/false RT Cleaner B=11:00/false'
      and (select hora from public.entradas_equipo where fecha = F and cleaner = A::uuid) = '09:30', r);

  -- 2. Quién ve las horas: drivers y líderes sí; un cleaner solo la suya
  perform pg_temp.como(LL); perform public.fijar_entrada(F, B::uuid, '12:00');
  perform pg_temp.como(DN); c := (select count(*) from public.entradas_equipo where cleaner::text like '00000000-0000-0000-0000-0000000010%');
  perform pg_temp.como(A);  r := (select string_agg(to_char(hora, 'HH24:MI'), ',') from public.entradas_equipo where cleaner::text like '00000000-0000-0000-0000-0000000010%');
  perform pg_temp.como(LN); e := (select count(*) = 0 from public.entradas_equipo);
  perform pg_temp.ok(2, 'Las horas las ven drivers y líderes; el cleaner solo la suya; linens no', c = 2 and r = '09:30' and e, c || ' / ' || coalesce(r, '-'));

  -- 3. La bolsa hereda la hora de su equipo como límite; el driver la ve en su lista y las listas en linens
  perform pg_temp.como(LN);
  perform public.bolsas_dia(F);
  select id into b1 from public.bolsas where limpieza_id = l1;
  perform public.preparar_bolsa(b1, true);
  perform public.preparar_bolsa((select id from public.bolsas where limpieza_id = l3), true);
  perform pg_temp.como(DN);
  j := public.mis_trabajos();
  r := (select string_agg((y->>'codigo') || '@' || (y->>'limite'), ',' order by y->>'limite') from jsonb_array_elements(j->'listas') y where y->>'codigo' like 'TEST-RT_');
  perform pg_temp.yo(); select token into tok from public.bolsas where id = b1;
  perform pg_temp.como(DN);
  perform public.escanear_bolsa('OPSFLOW-BAG:' || tok);
  x := (select y from jsonb_array_elements(public.mis_trabajos()->'bolsas') y where y->>'codigo' = 'TEST-RT1');
  perform pg_temp.ok(3, 'Bolsa: límite = entrada del equipo (A 09:30, B 12:00); en el camión lleva límite y punto confirmado',
    r = 'TEST-RT1@09:30,TEST-RT3@12:00' and x->>'limite' = '09:30' and (x->>'lat')::numeric = 35.95 and x->>'coord' = 'confirmada', r || ' ' || coalesce(x::text, '-'));

  -- 4. "Listo en 30 min": solo su limpieza en curso, una vez; la ve el tablero de drivers con la hora
  perform pg_temp.como(A);
  e := pg_temp.falla(format('select public.avisar_listo(%L)', l1));          -- aún no ha empezado
  perform public.iniciar_limpieza(l1);
  perform public.iniciar_limpieza(l2);
  av := public.avisar_listo(l1);
  e := e and pg_temp.falla(format('select public.avisar_listo(%L)', l1));     -- segunda vez
  perform pg_temp.como(B);
  e := e and pg_temp.falla(format('select public.avisar_listo(%L)', l1));     -- no es suya
  perform pg_temp.como(DN);
  x := (select y from jsonb_array_elements(public.tablero_zonas()) y where y->>'id' = av::text);
  perform pg_temp.yo();
  perform pg_temp.ok(4, 'Aviso: solo en curso, solo su limpieza, una vez; el driver lo ve con la hora (+30 min) y check-in',
    e and x->>'listo_a' = to_char((now() + interval '30 minutes') at time zone 'Europe/Malta', 'HH24:MI')
      and x->>'tipo' = 'recogida' and x->>'entrada' = '15:00' and (x->>'terminada')::boolean = false, coalesce(x::text, 'no lo ve'));

  -- 5. Push: a los drivers de esa zona ("Ready at HH:MM"), no a los de otra zona
  r := (select string_agg(a.titulo, ' | ') from public.avisos_para('pendiente', av) a);
  c := (select count(*) from public.avisos_enviados where id > (select max_av from _inicio) and perfil_id = DS::uuid);
  perform pg_temp.ok(5, 'Push "⚠ Ready at HH:MM: código" (tiene check-in) a los drivers de la zona; no a otra zona',
    r like '⚠ Ready at __:__: TEST-RT1' and c = 0, coalesce(r, 'sin aviso'));

  -- 6. Deshacer: en 5 minutos sí; después no
  perform pg_temp.como(A);
  perform public.deshacer_listo(l1);
  c := (select count(*) from public.pendientes where limpieza_id = l1);
  av := public.avisar_listo(l1);
  perform pg_temp.yo();
  update public.pendientes set creado_en = now() - interval '6 minutes' where id = av;
  perform pg_temp.como(A);
  r := pg_temp.error(format('select public.deshacer_listo(%L)', l1));
  perform pg_temp.ok(6, 'Deshacer: dentro de 5 min se borra el aviso; pasado ese tiempo, no', c = 0 and r like 'Too late%', c || ' ' || r);

  -- 7. El driver lo coge: sus paradas = la bolsa (límite 09:30) + la recogida ("no antes de" la hora de listo)
  perform pg_temp.como(DN);
  perform public.tomar_tarea(av);
  perform pg_temp.yo();
  j := public.paradas_driver(DN::uuid);
  r := (select string_agg((y->>'clase') || ':' || (y->>'codigo') || ':' || coalesce(to_char((y->>'limite')::timestamptz at time zone 'Europe/Malta', 'HH24:MI'), '-')
                          || ':' || case when y->>'no_antes' is null then '-' else 'espera' end || ':' || coalesce(y->>'lat', 'sinpunto'), ',' order by y->>'clase') from jsonb_array_elements(j->'paradas') y);
  perform pg_temp.ok(7, 'Paradas del driver: bolsa con límite 09:30 y punto; recogida con "no antes de"',
    r = 'bolsa:TEST-RT1:09:30:-:35.95,recogida:TEST-RT1:-:espera:35.95' and j->'bodega' ? 'enlace', r);

  -- 8. Al cerrar con basura, la basura va en la misma recogida (no se crea otra) y deja de tener "no antes de"
  perform pg_temp.como(A);
  perform public.linens_ok(l1);
  perform public.marcar_paso(l1, p.id, true) from public.checklist_pasos p where p.tipo = 'normal' and p.obligatorio;
  perform public.registrar_foto(l1, s, l1 || '/' || s || '.jpg') from unnest(array['bedroom','bathroom','kitchen','living']) s;
  perform pg_temp.yo();
  insert into public.fotos_cierre (limpieza_id, sala, ruta, subida_por) values (l1, 'basura', l1 || '/basura.jpg', A::uuid);
  perform pg_temp.como(A);
  j := public.cerrar_limpieza(l1, null, true, true, true, true, true);
  perform pg_temp.yo();
  c := (select count(*) from public.pendientes where limpieza_id = l1 and tipo = 'recogida');
  x := (select y from jsonb_array_elements(public.paradas_driver(DN::uuid)->'paradas') y where y->>'clase' = 'recogida');
  perform pg_temp.ok(8, 'Cerrar con basura: se une al aviso (1 sola recogida, con foto); ya no espera',
    c = 1 and (j->'pendientes'->>0)::uuid = av and (select foto from public.pendientes where id = av) = l1 || '/basura.jpg'
      and x->>'no_antes' is null, c || ' ' || j::text);

  -- 9. Sin aviso, el cierre sigue creando la recogida como antes; una vez recogida, deshacer ya no vale
  perform pg_temp.como(DN);
  perform public.marcar_entregado(av);
  perform pg_temp.como(A);
  r := pg_temp.error(format('select public.deshacer_listo(%L)', l1));
  perform pg_temp.ok(9, 'Recogida hecha por el driver: el cleaner ya no puede deshacer', r like 'A driver already%' or r like 'Too late%', r);

  -- 10. Lo que solo hace el servidor: nadie desde la app calcula paradas ni escribe rutas o el punto
  perform pg_temp.como(DN);
  e := pg_temp.falla(format('select public.paradas_driver(%L)', DN))
   and pg_temp.falla(format('select public.guardar_ruta(%L, %L, %L)', DN, 'x', '{}'))
   and pg_temp.falla('select public.guardar_bodega_resuelta(35.9, 14.4)')
   and pg_temp.falla('select public.fijar_bodega(35.9, 14.4)');
  perform pg_temp.como(OP);
  e := e and pg_temp.falla(format('select public.paradas_driver(%L)', DN));
  perform pg_temp.ok(10, 'paradas_driver, guardar_ruta y guardar_bodega_resuelta: solo el servidor; fijar_bodega solo Operación', e);

  -- 11. Rutas guardadas: cada driver ve la suya; el líder de drivers ve todas las de hoy
  perform pg_temp.yo();
  perform public.guardar_ruta(DN::uuid, 'f1', '{"paradas":[{"codigo":"TEST-RT1"}]}');
  perform public.guardar_ruta(DS::uuid, 'f2', '{"paradas":[]}');
  perform pg_temp.como(DN); c := (select count(*) from public.rutas_driver where driver::text like '00000000-0000-0000-0000-0000000010%');
  e := pg_temp.falla($q$update public.rutas_driver set firma = 'x' where true$q$);
  perform pg_temp.como(LD); j := public.rutas_hoy();
  r := (select string_agg(y->>'driver', ',' order by y->>'driver') from jsonb_array_elements(j) y where y->>'driver' like 'RT %');
  perform pg_temp.como(A);
  e := e and (select count(*) = 0 from public.rutas_driver) and pg_temp.falla('select public.rutas_hoy()');
  perform pg_temp.ok(11, 'Rutas: el driver solo la suya (y no la escribe); el líder de drivers todas; un cleaner ninguna', c = 1 and r = 'RT DrvNorte,RT DrvSur' and e, c || ' ' || coalesce(r, '-'));

  -- 12. Punto de bodega: Operación lo cambia (dentro de Malta); el servidor no pisa uno que ya existe
  perform pg_temp.como(OP);
  e := pg_temp.falla('select public.fijar_bodega(41.39, 2.17)');
  perform public.fijar_bodega(35.9000, 14.4500);
  perform pg_temp.yo();
  perform public.guardar_bodega_resuelta(35.8000, 14.5000);
  perform pg_temp.como(DN);
  x := (select to_jsonb(pb) from public.puntos_base pb where clave = 'bodega');
  perform pg_temp.ok(12, 'Bodega: fuera de Malta no; Operación la cambia; el servidor no la pisa; el driver la lee',
    e and (x->>'lat')::numeric = 35.9 and (x->>'lng')::numeric = 14.45, coalesce(x::text, 'no la ve'));
end $$;

-- Dejarlo todo como estaba
update public.puntos_base b set lat = o.lat, lng = o.lng, enlace = o.enlace, cambiado_por = o.cambiado_por, cambiado_en = o.cambiado_en
  from _bodega o where b.clave = o.clave;
delete from public.rutas_driver where driver::text like '00000000-0000-0000-0000-0000000010%';
delete from public.entradas_equipo where cleaner::text like '00000000-0000-0000-0000-0000000010%';
delete from public.pendientes where propiedad_id in (select id from public.propiedades where codigo like 'TEST-RT_');
delete from public.checkouts  where propiedad_id in (select id from public.propiedades where codigo like 'TEST-RT_');
delete from public.propiedades where codigo like 'TEST-RT_';
delete from public.avisos_enviados where id > (select max_av from _inicio);
delete from public.eventos where id > (select max_ev from _inicio);
delete from public.perfiles where id::text like '00000000-0000-0000-0000-0000000010%';
delete from auth.users      where id::text like '00000000-0000-0000-0000-0000000010%';

select * from resultados order by n;
