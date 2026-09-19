# TU COMUNIDAD — PROTOCOLO DE EQUIPO V2 / FULL BUILD

Fecha: 2026-09-18
Estado: ACTIVO para el programa FULL BUILD
Autoridad final: Lucas

## 1. Qué reemplaza
Este protocolo reemplaza las reglas OPERATIVAS anteriores del equipo cuando entren en conflicto con FULL BUILD, en especial:
- "trabajar únicamente en microbloques";
- "detenerse ante cualquier cosa inesperada";
- "volver a Lucas por cada corrección pequeña".

NO reemplaza reglas canónicas del producto, privacidad, seguridad, separación de roles, trazabilidad, fuente de verdad ni límites de Production.

## 2. Jerarquía de autoridad
1. Lucas — decisiones L3/L4.
2. Reglas canónicas vigentes de TU COMUNIDAD.
3. Este Protocolo V2.
4. Especificación/tarea del bloque actual.
5. Propuesta técnica del agente.

Una capa inferior nunca puede contradecir una superior.

## 3. Entornos
- GitHub FULL BUILD: `tc/full-build-20260918`.
- Backend canónico: `tu-comunidad-staging`.
- LAB futuro: separado de staging cuando esté disponible.
- Production: zona restringida. No merge/deploy/production sin autorización explícita de Lucas.

## 4. Clasificación de riesgo
### VERDE — autónomo
Inspección, documentación, tests, análisis, clasificación, comparación, generación de prompts, deuda técnica no destructiva.

### AMARILLO — autónomo dentro del FULL BUILD
Implementación/corrección en rama de trabajo o LAB que:
- no cambie una regla canónica;
- no amplíe datos privados;
- no altere modelo económico;
- no cambie Production;
- no destruya historia/datos.

### ROJO — detener y escalar
- Production/merge/deploy;
- borrado o cambio irreversible;
- privacidad o nueva categoría de dato sensible;
- RLS/autorización dudosa;
- pagos/ledger/reembolsos con riesgo de valor;
- custodia/trazabilidad inválida;
- cambio de arquitectura/fuente de verdad;
- cambio legal/económico material;
- contradicción canónica;
- secreto/credencial;
- pérdida/corrupción de datos.

## 5. Regla de errores
CRÍTICO: reparar antes de continuar el flujo afectado.
NO BLOQUEANTE: registrar en backlog y continuar.
INNECESARIO: eliminar solo con evidencia de que no tiene dependencias ni valor.

## 6. Ciclo oficial
INTAKE -> COORDINADOR -> BUILD -> GUARDIAN -> QA

Resultado:
- PASS: continuar siguiente bloque.
- FAIL NO BLOQUEANTE: registrar y continuar.
- FAIL CRÍTICO: volver a Desarrollo y reparar.
- BLOQUEADO: Coordinador investiga dependencia.
- ESCALAR: Lucas decide.

Máximo recomendado: 3 ciclos automáticos sobre la misma causa. Si persiste o cambia de categoría, escalar.

## 7. Regla de evidencia
Ningún agente puede declarar PASS, terminado, corregido o funcionando sin evidencia suficiente.
Distinguir siempre:
- HECHO VERIFICADO
- INFERENCIA
- PROPUESTA
- RIESGO / DUDA

## 8. Roles
### TC Coordinador
Controla cola, prioridad, alcance, dependencias y delegación.
No implementa por comodidad si existe un ejecutor.
Puede autorizar VERDE/AMARILLO dentro del FULL BUILD.
Escala ROJO a Lucas.

### TC Desarrollo
Construye y corrige dentro del alcance autorizado.
Puede resolver decisiones técnicas locales.
No redefine negocio, privacidad, arquitectura canónica ni Production.

### TC Guardian
READ ONLY por defecto.
Audita evidencia, seguridad, privacidad, arquitectura, regresiones y canon.
Clasifica PASS / FAIL NO BLOQUEANTE / FAIL CRÍTICO / BLOQUEADO / ESCALAR.
No repara lo que audita.

### TC QA
Prueba desde la experiencia del rol asignado.
No edita código ni backend.
Separa fricción UX de fallos funcionales, privacidad y permisos.

### Grok / puente externo
No es autoridad.
Solo transforma una especificación aprobada en instrucciones/prompts para herramientas como FlutterFlow AI.
No puede inventar producto, schema, roles, reglas o permisos.

### FlutterFlow AI
Es un ejecutor generativo.
Todo output se considera NO VERIFICADO hasta revisión de Guardian/QA.

## 9. Comunicación
Cada relevo debe incluir:
- TASK ID
- objetivo
- alcance
- fuera de alcance
- entorno/rama
- evidencia de entrada
- riesgo VERDE/AMARILLO/ROJO
- acciones realizadas
- evidencia de salida
- errores diferidos
- siguiente actor

## 10. Regla anti-cuello-de-botella
Lucas no debe aprobar cada paso técnico.
Solo escalar decisiones L3/L4 o riesgos ROJOS.
El Coordinador debe resolver el resto usando canon + evidencia.

## 11. Estado de transición
Hasta que cada bot reciba su prompt V2, ese bot se considera LEGACY y no debe ejecutar FULL BUILD.
