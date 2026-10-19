-- OpsFlow · pruebas del modulo cadena-checkout
-- Ejecutar DESPUES de 004. Supabase → SQL Editor → pegar todo → Run.
-- Crea 7 usuarios de prueba, recorre la cadena completa, lo deja todo como estaba
-- y muestra una tabla: todas las filas deben decir OK.

create temp table resultados (n int, prueba text, resultado text);

-- Ayudantes de la prueba (temporales, desaparecen al cerrar)
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
  insert into resultados values (n, prueba, case when cond then 'OK' else 'FALLO ' || coalesce(detalle, '') end);
end $$;

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-0000-0000-0000000000c1', 'cc.cleanera@opsflow.test', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000c2', 'cc.cleanerb@opsflow.test', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000c3', 'cc.drivern@opsflow.test',  'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000c4', 'cc.drivers@opsflow.test',  'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000c5', 'cc.lidlimp@opsflow.test',  'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000c6', 'cc.lidlin@opsflow.test',   'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000c7', 'cc.operacion@opsflow.test','authenticated', 'authenticated');
insert into public.perfiles (id, nombre, departamento, nivel, zona) values
  ('00000000-0000-0000-0000-0000000000c1', 'CC Cleaner A', 'Limpieza',  'operador',  'Norte'),
  ('00000000-0000-0000-0000-0000000000c2', 'CC Cleaner B', 'Limpieza',  'operador',  'Norte'),
  ('00000000-0000-0000-0000-0000000000c3', 'CC Driver N',  'Drivers',   'operador',  'Norte'),
  ('00000000-0000-0000-0000-0000000000c4', 'CC Driver S',  'Drivers',   'operador',  'Sur'),
  ('00000000-0000-0000-0000-0000000000c5', 'CC LidLimp',   'Limpieza',  'lider',     null),
  ('00000000-0000-0000-0000-0000000000c6', 'CC LidLin',    'Linens',    'lider',     null),
  ('00000000-0000-0000-0000-0000000000c7', 'CC Operacion', 'Operación', 'operacion', null);

do $$
declare
  A  text := '00000000-0000-0000-0000-0000000000c1';
  B  text := '00000000-0000-0000-0000-0000000000c2';
  DN text := '00000000-0000-0000-0000-0000000000c3';
  DS text := '00000000-0000-0000-0000-0000000000c4';
  LL text := '00000000-0000-0000-0000-0000000000c5';
  LN text := '00000000-0000-0000-0000-0000000000c6';
  OP text := '00000000-0000-0000-0000-0000000000c7';
  F  date := '2099-02-01';
  l1 uuid; l2 uuid; l3 uuid; pt uuid; pr uuid; po uuid;
  c int; j jsonb; e boolean; ev0 int; ev1 int;
begin
  -- 1. Cargar 3 checkouts crea 3 limpiezas
  perform pg_temp.como(OP);
  perform public.cargar_checkouts(F, E'TEST-N01 10:00 15:00\nTEST-N02 10:00\nTEST-N03 11:00', true);
  perform pg_temp.yo();
  select count(*) into c from public.limpiezas where fecha = F;
  perform pg_temp.ok(1, 'Cada checkout crea su limpieza (3)', c = 3, c::text);
  select l.id into l1 from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id where l.fecha = F and p.codigo = 'TEST-N01';
  select l.id into l2 from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id where l.fecha = F and p.codigo = 'TEST-N02';
  select l.id into l3 from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id where l.fecha = F and p.codigo = 'TEST-N03';

  -- 2. Recargar no duplica limpiezas
  perform pg_temp.como(OP);
  perform public.cargar_checkouts(F, E'TEST-N01 10:30 15:00\nTEST-N02 10:00', true);
  perform pg_temp.yo();
  select count(*) into c from public.limpiezas where fecha = F;
  perform pg_temp.ok(2, 'Recargar checkouts no duplica limpiezas', c = 3, c::text);

  -- 3. El cleaner no puede asignar
  perform pg_temp.como(A);
  e := pg_temp.falla(format('select public.asignar_limpieza(%L, %L, 1, ''normal'')', l1, A));
  perform pg_temp.ok(3, 'Un cleaner no puede asignar', e);

  -- 4. No se puede asignar a un driver
  perform pg_temp.como(LL);
  e := pg_temp.falla(format('select public.asignar_limpieza(%L, %L, 1, ''normal'')', l1, DN));
  perform pg_temp.ok(4, 'No se asigna una limpieza a un driver', e);

  -- 5. Lider asigna; antes de publicar el cleaner no ve nada
  perform pg_temp.como(LL);
  perform public.asignar_limpieza(l1, A::uuid, 1, 'normal');
  perform public.asignar_limpieza(l2, A::uuid, 2, 'refresh');
  perform public.asignar_limpieza(l3, B::uuid, 1, 'normal');
  perform pg_temp.como(A);
  j := public.mi_dia(F);
  select count(*) into c from public.limpiezas;
  perform pg_temp.ok(5, 'Antes de publicar el cleaner no ve sus limpiezas', jsonb_array_length(j) = 0 and c = 0);

  -- 6. Publicar: A ve 2 en orden, B ve 1
  perform pg_temp.como(LL);
  c := public.publicar_orden(F);
  perform pg_temp.como(A);
  j := public.mi_dia(F);
  perform pg_temp.como(B);
  perform pg_temp.ok(6, 'Publicado: A ve sus 2 en orden, B ve 1',
    c = 3 and jsonb_array_length(j) = 2 and (j->0->>'codigo') = 'TEST-N01' and jsonb_array_length(public.mi_dia(F)) = 1);

  -- 7. Terminar sin empezar falla; B no puede tocar la de A
  perform pg_temp.como(A);
  e := pg_temp.falla(format('select public.terminar_limpieza(%L)', l1));
  perform pg_temp.como(B);
  perform pg_temp.ok(7, 'No se termina sin empezar; nadie toca la limpieza de otro',
    e and pg_temp.falla(format('select public.iniciar_limpieza(%L)', l1)));

  -- 8. A empieza, reporta toalla (prioritario por check-in) y recogida
  perform pg_temp.como(A);
  perform public.iniciar_limpieza(l1);
  pt := public.reportar_pendiente(l1, 'linens', 'Toalla grande', 2);
  pr := public.reportar_pendiente(l1, 'recogida', '', 1);
  perform pg_temp.yo();
  perform pg_temp.ok(8, 'Pendiente con check-in queda prioritario',
    (select prioritario and estado = 'abierto' from public.pendientes where id = pt)
    and (select detalle = 'Basura y linens sucios' from public.pendientes where id = pr));

  -- 9. Linens ve solo lo de linens
  perform pg_temp.como(LN);
  select count(*) into c from public.pendientes where fecha = F;
  perform pg_temp.ok(9, 'Linens ve solo los pendientes de linens (1)', c = 1, c::text);

  -- 10. El driver no puede entregar antes de que linens prepare
  perform pg_temp.como(DN);
  e := pg_temp.falla(format('select public.marcar_entregado(%L)', pt));
  j := public.mi_ruta(F);
  perform pg_temp.ok(10, 'Driver: no entrega sin preparar; ve la recogida y el orden',
    e and jsonb_array_length(j->'tareas') = 1 and jsonb_array_length(j->'orden') = 3);

  -- 11. Linens prepara; el driver de otra zona no puede entregar ni ver
  perform pg_temp.como(LN);
  perform public.marcar_preparado(pt);
  perform pg_temp.como(DS);
  e := pg_temp.falla(format('select public.marcar_entregado(%L)', pt));
  select count(*) into c from public.pendientes;
  perform pg_temp.ok(11, 'El driver de otra zona no ve ni entrega', e and c = 0 and jsonb_array_length(public.mi_ruta(F)->'tareas') = 0);

  -- 12. Driver Norte: prioritario arriba, entrega y recoge
  perform pg_temp.como(DN);
  j := public.mi_ruta(F);
  perform public.marcar_entregado(pt);
  perform public.marcar_entregado(pr);
  perform pg_temp.yo();
  perform pg_temp.ok(12, 'Driver entrega la toalla y la recogida queda cerrada',
    jsonb_array_length(j->'tareas') = 2
    and (select estado = 'entregado' from public.pendientes where id = pt)
    and (select estado = 'cerrado' from public.pendientes where id = pr));

  -- 13. Solo el cleaner de la limpieza cierra el pendiente
  perform pg_temp.como(B);
  e := pg_temp.falla(format('select public.marcar_recibido(%L)', pt));
  perform pg_temp.como(LL);
  e := e and pg_temp.falla(format('select public.marcar_recibido(%L)', pt));
  perform pg_temp.como(A);
  perform public.marcar_recibido(pt);
  perform pg_temp.yo();
  perform pg_temp.ok(13, 'Solo el cleaner marca Received y queda cerrado',
    e and (select estado = 'cerrado' from public.pendientes where id = pt));

  -- 14. No pude entrar en la segunda limpieza de A
  perform pg_temp.como(A);
  e := pg_temp.falla(format('select public.no_pude_entrar(%L, %L)', l2, ''));
  perform public.no_pude_entrar(l2, 'Huésped dentro');
  -- (desde el modulo limpieza-guiada, terminar exige checklist y 4 fotos: se completan aqui si existen)
  perform pg_temp.yo();
  if to_regclass('public.checklist_pasos') is not null then
    execute format($q$update public.limpiezas l set checklist = (select coalesce(jsonb_object_agg(p.id::text, now()), '{}'::jsonb)
      from public.checklist_pasos p where p.tipo = l.tipo and p.activo) where l.id = %L$q$, l1);
    execute format($q$insert into public.fotos_cierre (limpieza_id, sala, ruta) select %L, s, %L || '/' || s || '.jpg'
      from unnest(array['bedroom','bathroom','kitchen','living']) s on conflict do nothing$q$, l1, l1);
  end if;
  perform pg_temp.como(A);
  perform public.terminar_limpieza(l1);
  perform pg_temp.yo();
  perform pg_temp.ok(14, 'No pude entrar exige motivo y queda registrado',
    e and (select estado = 'no_pude_entrar' and motivo_no_entrar = 'Huésped dentro' from public.limpiezas where id = l2));

  -- 15. Pendiente "otro": lo resuelve el lider
  perform pg_temp.como(A);
  po := public.reportar_pendiente(l1, 'otro', 'Bombilla fundida', 1);
  e := pg_temp.falla(format('select public.resolver_pendiente(%L)', po));
  perform pg_temp.como(LL);
  perform public.resolver_pendiente(po);
  perform pg_temp.yo();
  perform pg_temp.ok(15, 'Pendiente "otro" lo resuelve el líder, no el cleaner',
    e and (select estado = 'cerrado' from public.pendientes where id = po));

  -- 16. Tablero y registro
  perform pg_temp.como(OP);
  j := public.tablero(F);
  perform pg_temp.yo();
  select count(*) into ev0 from public.eventos where limpieza_id in (l1, l2, l3);
  perform pg_temp.ok(16, 'Tablero cuenta 3 cerrados, 0 abiertos y 1 no pude entrar; cada paso deja evento',
    (j->>'cerrados')::int = 3 and (j->>'en_linens')::int = 0 and (j->>'en_driver')::int = 0
    and (j->>'por_recibir')::int = 0 and jsonb_array_length(j->'no_pude_entrar') = 1 and ev0 >= 14, j::text || ' eventos=' || ev0);

  -- 17. Solo Operacion ve el registro; nadie escribe tablas directamente
  perform pg_temp.como(A);
  select count(*) into c from public.eventos;
  e := pg_temp.falla(format('update public.limpiezas set estado = ''terminada'' where id = %L', l3));
  e := e and pg_temp.falla(format('insert into public.pendientes (limpieza_id, propiedad_id, zona, fecha, tipo, detalle) select id, propiedad_id, zona, fecha, ''otro'', ''x'' from public.limpiezas where id = %L', l1));
  perform pg_temp.como(LN);
  e := e and pg_temp.falla('select public.tablero(''2099-02-01'')');
  perform pg_temp.ok(17, 'Solo Operación ve el registro y el tablero; nadie escribe directo', c = 0 and e);

  -- 18. Borrar datos TEST se lleva tambien limpiezas, pendientes y eventos (se deshace)
  begin
    perform pg_temp.como(OP);
    perform public.borrar_datos_prueba();
    perform pg_temp.yo();
    select count(*) into c from public.limpiezas where es_prueba;
    raise exception 'deshacer %', c;
  exception when others then
    perform pg_temp.yo();
    perform pg_temp.ok(18, 'Borrar datos TEST limpia también la cadena', sqlerrm = 'deshacer 0', sqlerrm);
  end;
end $$;

-- Dejarlo todo como estaba
delete from public.checkouts where fecha = '2099-02-01';
delete from public.perfiles where id::text like '00000000-0000-0000-0000-0000000000c%';
delete from auth.users      where id::text like '00000000-0000-0000-0000-0000000000c%';

select * from resultados order by n;
