-- OpsFlow · puntos REALES de Malta para los 20 apartamentos de PRUEBA (TEST-N01 … TEST-N20), zona Norte
-- Para que TomTom pueda armar rutas de verdad en el piloto. Ejecutar DESPUÉS de 27. Se puede ejecutar varias veces.
-- · Son puntos en calles públicas de cada pueblo (sacados de TomTom), SIN número de portal: no son apartamentos de 360.
-- · Solo toca propiedades marcadas como prueba (es_prueba) cuyo código empieza por TEST-N. Quedan "confirmadas".
-- · Al final muestra las 20 filas: todas deben decir "confirmada".
do $$
declare r record; n int := 0;
begin
  perform set_config('opsflow.coord', '1', true);   -- el estado se escribe aquí a propósito (solo prueba)
  for r in select * from (values
    ('TEST-N01', 'Triq Sammy Bartolo (punto de prueba)',        'Mellieħa',       35.957523, 14.363112),
    ('TEST-N02', 'Triq il-Qigħan (punto de prueba)',             'Mellieħa',       35.955490, 14.359308),
    ('TEST-N03', 'Triq il-Mitħna l-Ġdida (punto de prueba)',     'Mellieħa',       35.958961, 14.360405),
    ('TEST-N04', 'Dawret San Pawl (punto de prueba)',            'St Paul''s Bay', 35.946827, 14.398963),
    ('TEST-N05', 'Triq San Ġorġ (punto de prueba)',              'St Paul''s Bay', 35.947868, 14.403480),
    ('TEST-N06', 'Dawret San Pawl, lado este (punto de prueba)', 'St Paul''s Bay', 35.946648, 14.401804),
    ('TEST-N07', 'Triq in-Nakkri (punto de prueba)',             'Qawra',          35.955120, 14.421247),
    ('TEST-N08', 'Triq il-Qawra (punto de prueba)',              'Qawra',          35.956032, 14.424153),
    ('TEST-N09', 'Triq il-Fliegu (punto de prueba)',             'Qawra',          35.952164, 14.419245),
    ('TEST-N10', 'Triq is-Sallur (punto de prueba)',             'Qawra',          35.957466, 14.423023),
    ('TEST-N11', 'Triq il-Gandoffli (punto de prueba)',          'Buġibba',        35.950974, 14.413501),
    ('TEST-N12', 'Triq it-Turisti (punto de prueba)',            'Buġibba',        35.949024, 14.416312),
    ('TEST-N13', 'Dawret il-Gżejjer (punto de prueba)',          'Buġibba',        35.952152, 14.410065),
    ('TEST-N14', 'Triq J. Quintinus (punto de prueba)',          'Buġibba',        35.950199, 14.417872),
    ('TEST-N15', 'Telgħet ix-Xemxija (punto de prueba)',         'Xemxija',        35.950420, 14.385786),
    ('TEST-N16', 'Triq Raddet ir-Roti (punto de prueba)',        'Xemxija',        35.950157, 14.384017),
    ('TEST-N17', 'Dawret in-Nawfraġju (punto de prueba)',        'Xemxija',        35.951015, 14.388060),
    ('TEST-N18', 'Triq San Pawl (punto de prueba)',              'Mġarr',          35.920589, 14.366501),
    ('TEST-N19', 'Triq Lazzaru Pisani (punto de prueba)',        'Mġarr',          35.918884, 14.364119),
    ('TEST-N20', 'Triq San Pietru (punto de prueba)',            'Mġarr',          35.921455, 14.368541)
  ) as t(codigo, direccion, pueblo, lat, lng)
  loop
    update public.propiedades p
       set direccion = r.direccion || ', ' || r.pueblo, lat = r.lat, lng = r.lng,
           coord_estado = 'confirmada', coord_fuente = 'tomtom', coord_motivo = null,
           coord_info = jsonb_build_object('prueba', true, 'origen', 'calle pública (TomTom), sin número'),
           pueblo_tomtom = null, coord_confirmada_por = null, coord_confirmada_en = now()
     where p.codigo = r.codigo and p.es_prueba;
    if found then
      n := n + 1;
      insert into public.eventos (quien, que, propiedad_id)
      select null, 'punto de prueba real (calle pública) confirmado', id from public.propiedades where codigo = r.codigo;
    end if;
  end loop;
  perform set_config('opsflow.coord', '', true);
  raise notice 'Puntos de prueba guardados: %', n;
end $$;

select codigo, pueblo, direccion, round(lat::numeric, 5) as lat, round(lng::numeric, 5) as lng, coord_estado
from public.propiedades where codigo like 'TEST-N%' and es_prueba order by codigo;
