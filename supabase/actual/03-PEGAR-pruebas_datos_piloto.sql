-- OpsFlow · pruebas del modulo datos-piloto
-- Ejecutar DESPUES de 002 y 003. Supabase → SQL Editor → pegar todo → Run.
-- Crea 5 usuarios de prueba, comprueba accesos y cargas, lo deja todo como estaba
-- y muestra una tabla: todas las filas deben decir OK.

create temp table resultados (n int, prueba text, resultado text);

insert into auth.users (id, email, aud, role) values
  ('00000000-0000-0000-0000-0000000000b1', 'dp.operador@opsflow.test',  'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000b2', 'dp.lidlimp@opsflow.test',   'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000b3', 'dp.lidlin@opsflow.test',    'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000b4', 'dp.operacion@opsflow.test', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000b5', 'dp.inactivo@opsflow.test',  'authenticated', 'authenticated');
insert into public.perfiles (id, nombre, departamento, nivel, zona, activo) values
  ('00000000-0000-0000-0000-0000000000b1', 'DP Operador',  'Limpieza',  'operador',  'Norte', true),
  ('00000000-0000-0000-0000-0000000000b2', 'DP LidLimp',   'Limpieza',  'lider',     null,    true),
  ('00000000-0000-0000-0000-0000000000b3', 'DP LidLin',    'Linens',    'lider',     null,    true),
  ('00000000-0000-0000-0000-0000000000b4', 'DP Operacion', 'Operación', 'operacion', null,    true),
  ('00000000-0000-0000-0000-0000000000b5', 'DP Inactivo',  'Limpieza',  'lider',     null,    false);

do $$
declare
  OP  text := '00000000-0000-0000-0000-0000000000b1';
  LL  text := '00000000-0000-0000-0000-0000000000b2';
  LN  text := '00000000-0000-0000-0000-0000000000b3';
  OPE text := '00000000-0000-0000-0000-0000000000b4';
  INA text := '00000000-0000-0000-0000-0000000000b5';
  F   date := '2099-01-01';
  c int; c2 int; fallo boolean; r jsonb; real_ok boolean;
begin
  -- helper: como(uid) = actuar como esa persona
  -- 1. Operador no ve propiedades
  perform set_config('request.jwt.claims', json_build_object('sub', OP, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  select count(*) into c from public.propiedades;
  perform set_config('role', 'none', true);
  insert into resultados values (1, 'Operador no ve propiedades', case when c = 0 then 'OK' else 'FALLO: ve ' || c end);

  -- 2. Lider de linens ve las 20 de prueba
  perform set_config('request.jwt.claims', json_build_object('sub', LN, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  select count(*) into c from public.propiedades where es_prueba;
  perform set_config('role', 'none', true);
  insert into resultados values (2, 'Lider de linens ve las 20 propiedades TEST', case when c = 20 then 'OK' else 'FALLO: ve ' || c end);

  -- 3. Cuenta desactivada no ve nada
  perform set_config('request.jwt.claims', json_build_object('sub', INA, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  select count(*) into c from public.propiedades;
  perform set_config('role', 'none', true);
  insert into resultados values (3, 'Cuenta desactivada no ve propiedades', case when c = 0 then 'OK' else 'FALLO: ve ' || c end);

  -- 4. Lider de limpieza no puede crear propiedades
  perform set_config('request.jwt.claims', json_build_object('sub', LL, 'role', 'authenticated')::text, true);
  fallo := false;
  begin
    perform set_config('role', 'authenticated', true);
    insert into public.propiedades (codigo, nombre, zona, pueblo) values ('DPX-1', 'x', 'Norte', 'x');
  exception when others then fallo := true;
  end;
  perform set_config('role', 'none', true);
  insert into resultados values (4, 'Lider de limpieza no puede crear propiedades', case when fallo then 'OK' else 'FALLO' end);

  -- 5. Operacion si puede crear y editar
  perform set_config('request.jwt.claims', json_build_object('sub', OPE, 'role', 'authenticated')::text, true);
  fallo := false;
  begin
    perform set_config('role', 'authenticated', true);
    insert into public.propiedades (codigo, nombre, zona, pueblo, es_prueba) values ('DPX-2', 'x', 'Norte', 'x', true);
    update public.propiedades set notas = 'editada' where codigo = 'DPX-2';
  exception when others then fallo := true;
  end;
  perform set_config('role', 'none', true);
  select count(*) into c from public.propiedades where codigo = 'DPX-2' and notas = 'editada';
  insert into resultados values (5, 'Operacion crea y edita propiedades', case when not fallo and c = 1 then 'OK' else 'FALLO' end);

  -- 6. Operador no puede cargar checkouts
  perform set_config('request.jwt.claims', json_build_object('sub', OP, 'role', 'authenticated')::text, true);
  fallo := false;
  begin
    perform set_config('role', 'authenticated', true);
    perform public.cargar_checkouts(F, 'TEST-N01 10:00', true);
  exception when others then fallo := true;
  end;
  perform set_config('role', 'none', true);
  insert into resultados values (6, 'Operador no puede cargar checkouts', case when fallo then 'OK' else 'FALLO' end);

  -- 7. Lider de linens no puede cargar checkouts
  perform set_config('request.jwt.claims', json_build_object('sub', LN, 'role', 'authenticated')::text, true);
  fallo := false;
  begin
    perform set_config('role', 'authenticated', true);
    perform public.cargar_checkouts(F, 'TEST-N01 10:00', true);
  exception when others then fallo := true;
  end;
  perform set_config('role', 'none', true);
  insert into resultados values (7, 'Lider de linens no puede cargar checkouts', case when fallo then 'OK' else 'FALLO' end);

  -- 8. Revisar sin confirmar: detecta todo y NO guarda
  perform set_config('request.jwt.claims', json_build_object('sub', LL, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  r := public.cargar_checkouts(F, E'TEST-N01 10:00\ntest-n02 9.30 15:00\nNOEXISTE-9 10:00\nTEST-N03 25:00\n\nTEST-N01 11:00\nbasura', false);
  perform set_config('role', 'none', true);
  select count(*) into c from public.checkouts where fecha = F;
  insert into resultados values (8, 'Revisar: 2 buenas, 4 rechazadas, nada guardado',
    case when jsonb_array_length(r->'cargados') = 2 and jsonb_array_length(r->'rechazados') = 4
              and (r->>'guardado')::boolean = false and c = 0 then 'OK'
         else 'FALLO: ' || r::text end);

  -- 9. Confirmar: guarda las 2 buenas
  perform set_config('role', 'authenticated', true);
  r := public.cargar_checkouts(F, E'TEST-N01 10:00\ntest-n02 9.30 15:00\nNOEXISTE-9 10:00', true);
  perform set_config('role', 'none', true);
  select count(*) into c from public.checkouts where fecha = F;
  insert into resultados values (9, 'Confirmar guarda solo las lineas buenas', case when c = 2 then 'OK' else 'FALLO: ' || c end);

  -- 10. Volver a cargar el mismo codigo actualiza, no duplica
  perform set_config('role', 'authenticated', true);
  r := public.cargar_checkouts(F, 'TEST-N01 11:30', true);
  perform set_config('role', 'none', true);
  select count(*) into c from public.checkouts where fecha = F;
  select count(*) into c2 from public.checkouts ch join public.propiedades p on p.id = ch.propiedad_id
   where ch.fecha = F and p.codigo = 'TEST-N01' and ch.hora_salida = '11:30';
  insert into resultados values (10, 'Recargar un codigo lo actualiza sin duplicar',
    case when jsonb_array_length(r->'actualizados') = 1 and c = 2 and c2 = 1 then 'OK' else 'FALLO' end);

  -- 11. Con entrada el mismo dia queda prioritario
  select count(*) into c from public.checkouts ch join public.propiedades p on p.id = ch.propiedad_id
   where ch.fecha = F and p.codigo = 'TEST-N02' and ch.prioritario;
  insert into resultados values (11, 'Checkout con entrada queda prioritario', case when c = 1 then 'OK' else 'FALLO' end);

  -- 12. Nadie escribe checkouts directamente (ni Operacion)
  perform set_config('request.jwt.claims', json_build_object('sub', OPE, 'role', 'authenticated')::text, true);
  fallo := false;
  begin
    perform set_config('role', 'authenticated', true);
    delete from public.checkouts where fecha = F;
    get diagnostics c = row_count;
    if c = 0 then raise exception 'nada borrado'; end if;
  exception when others then fallo := true;
  end;
  perform set_config('role', 'none', true);
  insert into resultados values (12, 'Nadie borra checkouts directamente', case when fallo then 'OK' else 'FALLO' end);

  -- 13. Lider de limpieza no puede generar dias de prueba
  perform set_config('request.jwt.claims', json_build_object('sub', LL, 'role', 'authenticated')::text, true);
  fallo := false;
  begin
    perform set_config('role', 'authenticated', true);
    perform public.generar_dia_prueba(F + 1);
  exception when others then fallo := true;
  end;
  perform set_config('role', 'none', true);
  insert into resultados values (13, 'Solo Operacion genera dias de prueba', case when fallo then 'OK' else 'FALLO' end);

  -- 14. Operacion genera un dia de prueba (8 a 14)
  perform set_config('request.jwt.claims', json_build_object('sub', OPE, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  c := public.generar_dia_prueba(F + 1);
  perform set_config('role', 'none', true);
  insert into resultados values (14, 'Generar dia de prueba crea entre 8 y 14', case when c between 8 and 14 then 'OK' else 'FALLO: ' || c end);

  -- 15. Borrar datos de prueba NO toca datos reales (se deshace al terminar)
  real_ok := false; c := -1;
  begin
    insert into public.propiedades (codigo, nombre, zona, pueblo, es_prueba) values ('DPX-REAL', 'real', 'Norte', 'x', false);
    insert into public.checkouts (propiedad_id, fecha, hora_salida) select id, F, '10:00' from public.propiedades where codigo = 'DPX-REAL';
    perform set_config('role', 'authenticated', true);
    r := public.borrar_datos_prueba();
    perform set_config('role', 'none', true);
    select count(*) into c from public.propiedades where es_prueba;
    real_ok := exists (select 1 from public.propiedades where codigo = 'DPX-REAL')
           and exists (select 1 from public.checkouts ch join public.propiedades p on p.id = ch.propiedad_id where p.codigo = 'DPX-REAL');
    raise exception 'deshacer';
  exception when others then
    perform set_config('role', 'none', true);
  end;
  insert into resultados values (15, 'Borrar TEST no toca datos reales', case when c = 0 and real_ok then 'OK' else 'FALLO' end);
end $$;

-- Dejarlo todo como estaba
delete from public.checkouts where fecha in ('2099-01-01', '2099-01-02');
delete from public.propiedades where codigo like 'DPX-%';
delete from public.perfiles where id::text like '00000000-0000-0000-0000-0000000000b%';
delete from auth.users      where id::text like '00000000-0000-0000-0000-0000000000b%';

select * from resultados order by n;
