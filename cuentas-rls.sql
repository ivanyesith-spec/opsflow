-- OpsFlow · pruebas de acceso del modulo cuentas
-- Supabase → SQL Editor → pegar todo → Run.
-- Crea 4 usuarios de prueba, comprueba quien ve que, los borra
-- y al final muestra una tabla: todas las filas deben decir OK.

create temp table resultados (n int, prueba text, resultado text);

-- Usuarios de prueba (se borran al final)
insert into auth.users (id, email, aud, role) values
  ('00000000-0000-0000-0000-0000000000a1', 'test.operador@opsflow.test',  'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000a2', 'test.driver@opsflow.test',    'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000a3', 'test.lider@opsflow.test',     'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000a4', 'test.operacion@opsflow.test', 'authenticated', 'authenticated');

insert into public.perfiles (id, nombre, departamento, nivel, zona) values
  ('00000000-0000-0000-0000-0000000000a1', 'TEST Operador', 'Limpieza',  'operador',  'Norte'),
  ('00000000-0000-0000-0000-0000000000a2', 'TEST Driver',   'Drivers',   'operador',  'Norte'),
  ('00000000-0000-0000-0000-0000000000a3', 'TEST Lider',    'Limpieza',  'lider',     null),
  ('00000000-0000-0000-0000-0000000000a4', 'TEST Operacion','Operación', 'operacion', null);

do $$
declare
  op  constant text := '00000000-0000-0000-0000-0000000000a1';
  lid constant text := '00000000-0000-0000-0000-0000000000a3';
  ope constant text := '00000000-0000-0000-0000-0000000000a4';
  test_ids uuid[] := array['00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-0000000000a2',
                           '00000000-0000-0000-0000-0000000000a3','00000000-0000-0000-0000-0000000000a4']::uuid[];
  c int; fallo boolean;
begin
  -- 1. Operador ve solo su perfil
  perform set_config('request.jwt.claims', json_build_object('sub', op, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  select count(*) into c from public.perfiles where id = any(test_ids);
  perform set_config('role', 'none', true);
  insert into resultados values (1, 'Operador ve solo su perfil (1)', case when c = 1 then 'OK' else 'FALLO: ve ' || c end);

  -- 2. Lider ve solo su departamento (Limpieza: el y el operador = 2)
  perform set_config('request.jwt.claims', json_build_object('sub', lid, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  select count(*) into c from public.perfiles where id = any(test_ids);
  perform set_config('role', 'none', true);
  insert into resultados values (2, 'Lider ve solo su departamento (2)', case when c = 2 then 'OK' else 'FALLO: ve ' || c end);

  -- 3. Operacion ve todos (4)
  perform set_config('request.jwt.claims', json_build_object('sub', ope, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  select count(*) into c from public.perfiles where id = any(test_ids);
  perform set_config('role', 'none', true);
  insert into resultados values (3, 'Operacion ve todos (4)', case when c = 4 then 'OK' else 'FALLO: ve ' || c end);

  -- 4. Nadie puede crear perfiles desde la app (ni Operacion)
  fallo := false;
  begin
    perform set_config('role', 'authenticated', true);
    insert into public.perfiles (id, nombre, departamento) values (gen_random_uuid(), 'Intruso', 'Limpieza');
  exception when others then fallo := true;
  end;
  perform set_config('role', 'none', true);
  insert into resultados values (4, 'Crear perfil desde la app esta bloqueado', case when fallo then 'OK' else 'FALLO: se pudo crear' end);

  -- 5. Un operador no puede subirse de nivel
  perform set_config('request.jwt.claims', json_build_object('sub', op, 'role', 'authenticated')::text, true);
  fallo := false;
  begin
    perform set_config('role', 'authenticated', true);
    update public.perfiles set nivel = 'operacion' where id = op::uuid;
  exception when others then fallo := true;
  end;
  perform set_config('role', 'none', true);
  select count(*) into c from public.perfiles where id = op::uuid and nivel = 'operador';
  insert into resultados values (5, 'Operador no puede cambiar su nivel', case when fallo and c = 1 then 'OK' else 'FALLO' end);

  -- 6. Sin sesion (anon) no se ve nada
  fallo := false;
  begin
    perform set_config('request.jwt.claims', '{"role":"anon"}', true);
    perform set_config('role', 'anon', true);
    select count(*) into c from public.perfiles;
  exception when others then fallo := true;
  end;
  perform set_config('role', 'none', true);
  insert into resultados values (6, 'Sin sesion no se ve ningun perfil', case when fallo or c = 0 then 'OK' else 'FALLO: ve ' || c end);

  -- 7. "Ya cambie mi clave" solo afecta a quien lo marca
  perform set_config('request.jwt.claims', json_build_object('sub', op, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  perform public.clave_cambiada();
  perform set_config('role', 'none', true);
  select count(*) into c from public.perfiles where id = any(test_ids) and debe_cambiar_clave = false;
  insert into resultados values (7, 'Marcar clave cambiada solo afecta al propio', case when c = 1 then 'OK' else 'FALLO: cambio ' || c end);

  -- 8. Lider desactivado pierde la vista de su departamento
  update public.perfiles set activo = false where id = lid::uuid;
  perform set_config('request.jwt.claims', json_build_object('sub', lid, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
  select count(*) into c from public.perfiles where id = any(test_ids);
  perform set_config('role', 'none', true);
  insert into resultados values (8, 'Lider desactivado solo ve su propio perfil (1)', case when c = 1 then 'OK' else 'FALLO: ve ' || c end);
end $$;

-- Limpieza: borrar los usuarios de prueba
delete from public.perfiles where id::text like '00000000-0000-0000-0000-0000000000a%';
delete from auth.users      where id::text like '00000000-0000-0000-0000-0000000000a%';

select * from resultados order by n;
