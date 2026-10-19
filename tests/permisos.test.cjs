// OpsFlow · pruebas locales (sin red ni Supabase) de la etapa 1: asignación solo por el líder + sustituciones.
// Ejecutar desde la raíz del repo:  node tests/permisos.test.cjs
// NO sustituyen a supabase/migraciones/35-PEGAR-pruebas_permisos.sql ni a las E2E.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const raiz = path.join(__dirname, '..');
const leer = (...p) => fs.readFileSync(path.join(raiz, ...p), 'utf8').replace(/\r\n/g, '\n');
const html = leer('index.html');
const sql = leer('supabase', 'migraciones', '34-PEGAR-permisos_sustituciones.sql');
let n = 0;
const prueba = (nombre, f) => { f(); n++; console.log('OK  ' + nombre); };

// 1. Los scripts de index.html siguen siendo JavaScript válido
prueba('index.html: todos los <script> en línea compilan', () => {
  const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1]);
  assert.ok(scripts.length > 0);
  scripts.forEach((s, i) => new vm.Script(s, { filename: `index.html#script${i}` }));
});

// 2. Pestañas por rol (se ejecuta el tabsDe real de index.html)
const fuente = html.match(/const asignaDe = [^\n]+\n/)[0] + html.match(/function tabsDe\(\)\{[\s\S]*?\n\}\n/)[0];
const tabs = perfil => {
  const ctx = { perfil };
  vm.runInNewContext(fuente + 'resultado = tabsDe().map(t => t[0]);', ctx);
  return ctx.resultado;
};
prueba('Operación: Seguimiento y Sustituciones, pero NO Asignar', () => {
  const t = tabs({ nivel: 'operacion', departamento: 'Operación' });
  assert.ok(!t.includes('asignar'));
  for (const k of ['seguimiento', 'drivers', 'linens', 'tablero', 'sustituciones']) assert.ok(t.includes(k), k);
});
prueba('Líder de limpieza: Asignar y Seguimiento, sin Sustituciones', () => {
  const t = tabs({ nivel: 'lider', departamento: 'Limpieza' });
  assert.ok(t.includes('asignar') && t.includes('seguimiento'));
  assert.ok(!t.includes('sustituciones'));
});
prueba('Otros líderes no ven Asignar ni Sustituciones', () => {
  for (const dep of ['Drivers', 'Linens', 'Bodega']) {
    const t = tabs({ nivel: 'lider', departamento: dep });
    assert.ok(!t.includes('asignar') && !t.includes('sustituciones'), dep);
  }
});

// 3. Drivers: el selector "Asignar a…" solo para el líder de drivers (o su sustituto)
prueba('Selector de asignar driver condicionado a asignaDe("Drivers")', () => {
  assert.match(html, /asignaDe\('Drivers'\) \? `<select data-asig=/);
  assert.equal((html.match(/data-asig="/g) || []).length, 1, 'no debe haber otro selector data-asig sin condición');
});

// 4. Migración: ninguna función de asignación deja pasar a Operación
const cuerpo = nombre => {
  const m = sql.match(new RegExp(`create or replace function public\\.${nombre}\\([\\s\\S]*?end \\$\\$;`));
  assert.ok(m, 'falta ' + nombre);
  return m[0];
};
prueba('SQL: las 6 funciones de asignación usan _asigna() y no mencionan operacion', () => {
  const dep = { asignar_limpieza: 'Limpieza', publicar_orden: 'Limpieza', guardar_equipo: 'Limpieza',
                deshacer_equipo: 'Limpieza', fijar_entrada: 'Limpieza', asignar_tarea: 'Drivers' };
  for (const [f, d] of Object.entries(dep)) {
    const c = cuerpo(f);
    assert.ok(c.includes(`public._asigna('${d}')`), f);
    assert.ok(!/operacion|_lider_limpieza/.test(c), f + ' todavía deja pasar a Operación');
  }
});
prueba('SQL: _asigna no incluye Operación y no se puede llamar desde la app', () => {
  assert.match(sql, /_asigna\(p_dep text\)[\s\S]*?mi_nivel\(\) = 'lider' and public\.mi_departamento\(\) = p_dep/);
  assert.match(sql, /revoke execute on function public\._asigna\(text\) from public, anon, authenticated;/);
});
prueba('SQL: sustituto solo de su propio departamento y solo dentro de las fechas', () => {
  const c = sql.match(/create or replace function public\.mi_nivel\(\)[\s\S]*?\$\$;/)[0];
  for (const x of ["p.nivel = 'operador'", 's.departamento = p.departamento', 's.revocada_en is null', 'now() >= s.desde', 'now() < s.hasta'])
    assert.ok(c.includes(x), x);
});
prueba('SQL: nombrar/revocar solo Operación; tabla cerrada al navegador', () => {
  assert.ok(cuerpo('nombrar_sustituto').includes("mi_nivel() is distinct from 'operacion'"));
  assert.ok(cuerpo('revocar_sustitucion').includes("mi_nivel() is distinct from 'operacion'"));
  assert.match(sql, /revoke all on public\.sustituciones from anon, authenticated;/);
});

// 5. Idiomas: los textos nuevos tienen traducción en el diccionario EN/ES
prueba('I18N: textos de sustituciones y mensajes del servidor traducidos', () => {
  const dic = html.match(/const I18N_DIC = `([\s\S]*?)`;/)[1];
  const claves = new Set(dic.split('\n').filter(l => l.includes(' | ')).map(l => l.slice(0, l.indexOf(' | ')).trim()));
  const mensajes = [...sql.matchAll(/raise exception '([^']+)'/g)].map(m => m[1]).filter(m => /sustitut|Solo el líder|Solo Operación/.test(m));
  for (const k of ['Sustituciones', 'Nombrar sustituto', 'Revocar', 'Vigente', 'Programada', 'Revocada', 'Sin driver', ...mensajes]) {
    const clave = k.replace(/\d+/g, '#').replace(/%/g, '{0}');
    assert.ok(claves.has(clave), 'sin traducción: ' + clave);
  }
});

console.log(`\n${n} pruebas OK`);
