dor huella digital del token de actualización (estable) así que la rotación de tokens no crea carriles duplicados. Usa `--add-dir` para contención. Útil cuando quieres modelos del ecosistema de Google sin manejar una clave API directamente. La bandera `--print` lo hace no interactivo y amigable con scripts.

### copilot

La **red de seguridad medida**. 200 créditos mensuales, renuevan mensualmente, `overage_permitted: false` — se detiene en lugar de facturar. Auto-enrutado (sin selector de modelo, un bucket con "auto"). Intentado último por defecto, solo cuando todos los carriles gratis están ocupados o fríos. Usa `--allow-all` + `--add-dir` para contención. Su fortaleza no es volumen sino fiabilidad — los modelos de GitHub tienden a ser bien probados y actualizados.

### cursor

El **segundo carril medido**, similar a copilot: auto-enrutado, asignación mensual agotable, intentado último. Reporta email de cuenta vía `cursor-agent status`. Usa `-f` para confiar en el directorio (se rechaza ejecutar headless de otra manera). Como copilot, su valor es como fallback cuando los carriles gratis están agotados — no como trabajador principal.

## Roles de orquestación

Cuando el coordinador decide que una tarea se divide en piezas independientes, surgen tres roles conceptuales. Estos no están atados a agentes específicos — son sobre qué hace quién durante una ejecución.

### Coordinador (tú, en el TUI)

El agente con el que estás hablando. Decide qué construir, mantiene el trabajo pequeño para sí mismo, y envía las piezas sustanciales y auto-contenidas a los trabajadores.

Su trabajo es:
- **Mantener contexto** — tu sesión TUI ya tiene el proyecto cargado. No envíes una tarea que requiera leer código que puedes entregar al trabajador en la especificación.
- **Escribir especificaciones auto-contenidas** — un trabajador recibe una cadena, no un repositorio. Si necesita coincidir con el estilo existente, cita el código relevante en el prompt.
- **Proteger la puerta** — solo dividir cuando 2+ tareas tienen conjuntos de archivos disjuntos Y 2+ carriles están disponibles. Con un carril, trabajar directamente es estrictamente mejor.
- **Mantener las cosas pequeñas** — arreglos de una línea, renombres, ajustes de config, archivos de pegamento cuestan más a un carril que a ti. Si escribir la especificación toma tanto como hacer el trabajo, haz el trabajo.
- **Registrar juicio** — la herramienta ve salidas, no intención. Cuando una especificación fue ambigua, una división causó una colisión, o un trabajador perdió el punto, escríbelo con `fa findings`. Esas observaciones se pierden cuando la sesión cierra.

### Trabajadores (agentes enviados)

Agentes de arranque frío que reciben un prompt auto-contenido, lo ejecutan, y reportan de vuelta. No hablan contigo, no ven otras tareas, y no pueden hacer preguntas.

Sus restricciones:
- **Sin estado compartido** — cada trabajador obtiene su propio worktree (cuando `--isolate` está activo) y no ve nada de los otros.
- **Sin conversación** — el prompt debe estar completo. El trabajador nunca ve esta conversación.
- **Archivos declarados son obligatorios** — tareas superpuestas nunca corren juntas. Los archivos se verifican después de la ejecución; archivos byte-identicos cuentan como no verificados.
- **La categoría importa** — las tareas declaran una categoría (`coding`, `reasoning`, `research`, `general`, `fast`). El programa rastrea qué modelos tienen éxito por categoría y clasifica las elecciones futuras acordemente. Un modelo bueno para coding puede ser malo para investigación — la categoría mantiene esa señal separada.

### Trabajo que espera

Algunas tareas no pueden hacerse aún: necesitan credenciales que no tienes, un servicio que no está provisionado, o una decisión que solo tú puedes marcalas con un campo `blocked` — nunca se envían, nunca se cuentan como fallos, y cualquier cosa que dependa de ellas espera con ellas. Cuando las desbloqueas, `fa resume` las recoge. El coordinador debería preguntar antes de asumir que algo está bloqueado.

### Categorías de trabajo

El campo `category` en una tarea no es cosmético — maneja la selección de modelo:

| Categoría | Mejor para | Qué aprende el programador |
|-----------|------------|---------------------------|
| **coding** | Implementación, funcionalidades, arreglos | Qué modelos escriben código correcto, respetan límites de archivos, siguen especificaciones |
| **reasoning** | Depuración, análisis de causa raíz, decisiones de diseño | Qué modelos razonan sobre compensaciones, rastrean lógica, explican claramente |
| **research** | Comparar opciones, evaluar enfoques, leer docs | Qué modelos sintetizan información, citan fuentes, evitan alucinación |
| **general** | Tareas mixtas que no encajan arriba | Calidad general del modelo en trabajo variado |
| **fast** | Consultas simples, formateo, ajustes de archivo único | Qué modelos son rápidos sin ser descuidados |

### Modos de proyecto

Cuánta autonomía tienen los trabajadores, por proyecto:

| Modo | Cuándo usarlo | Comportamiento |
|------|-------------|----------------|
| **strict** (default) | Código no revisado, ramas compartidas | Trabajadores proponen cambios, coordinador revisa antes de fusionar |
| **push** | Proyectos personales, carriles confiables | Trabajadores fusionan sus propios worktrees después de pasar verificación |
| **local** | Trabajo experimental, ramas de prueba | Trabajadores operan en el árbol principal, sin aislamiento |

Configura con `fa config --mode push` o editando `.orch/config.yaml`. El orquestador (`fa orch run`) lee el modo y ajusta el comportamiento de aislamiento acordemente.

## Agentes soportados

| Agente | Ubicación | Fuente de identidad | Notas |
|-------|----------|-----------------|-------|
| opencode | `/usr/local/nodejs/bin/opencode` | `~/.local/share/opencode/auth.json` | También tiene modelos zen (hospedados, sin credencial) |
| kilo | `/usr/local/nodejs/bin/kilo` | no autenticado | 23 modelos gratis, sin clave necesaria |
| hermes | `hermes` en PATH | `~/.hermes/auth.json` | Multi-proveedor (nous, kilo, etc.) |
| copilot | `/usr/local/nodejs/bin/copilot` | GitHub OAuth | Medido (200 créditos, renueva mensualmente) |
| cursor | `/usr/local/nodejs/bin/cursor-agent` | estado de cursor | Medido |
| agy | `~/.local/bin/agy` | Google OAuth | 14+ modelos gratis (Gemini, Claude, GPT) |
| pi | `/usr/local/nodejs/bin/pi` | `~/.pi/agent/auth.json` | Respaldado por OpenRouter |

## Características

| Característica | Qué hace |
|---------|--------------|
| **Detección de carriles** | Descubre cada credencial que tus agentes poseen, atribuye cada modelo a su billetera |
| **Envío paralelo** | Ejecuta tareas independientes en carriles separados simultáneamente |
| **Ejecución aislada** | Ejecuta tareas en worktrees de git para prevenir colisiones (`--isolate`) |
| **Cadena de alternativas** | Intenta el siguiente carril sano cuando uno falla — sin intervención manual |
| **Disyuntor de bucket** | Congela una billetera después de fallos consecutivos, omite todos sus modelos instantáneamente |
| **Clasificaciones aprendidas** | Clasifica modelos por resultados observados por categoría (coding, reasoning, research) |
| **Resumen seguro** | Registro de solo añadir; resume cualquier ejecución después de interrupción |
| **Carriles medidos** | Auto-incluye copilot/cursor cuando se detectan con créditos, intentados últimos |
| **Puerta de verificación** | Verificación de sintaxis post-construcción opcional con bucle de auto-arreglo (`--validate`) |
| **Modos de proyecto** | Autonomía por proyecto: strict (default), push, local |
| **Handoffs** | Tareas pasan resúmenes de una línea a dependientes; sin llamada de modelo extra |
| **Findings** | Registra lo que la herramienta notó que manejó mal; copiable a issues |

## Bootstrap (una vez por máquina)

```sh
fa bootstrap    # descubrir credenciales, probar billeteras, instalar habilidades
fa doctor       # verificar la máquina
fa lanes -v     # con lo que terminaste
```

`bootstrap` lee las credenciales que tus agentes ya poseen — nunca pide claves y nunca almacena una. El registro es **de máquina** en `~/.local/state/free-agents`. Un bootstrap sirve para cada proyecto en la caja.

`bootstrap` instala una **actualización diaria** en crontab, así que un clon fresco no necesita paso manual. `fa schedule` / `fa unschedule` lo manejan.

## Añadir un nuevo agente

1. Crea `bin/lib/adapters/<agente>.sh` — implementa `agent_identify`, `agent_models`, `agent_invoke`
2. Añade al array `FA_AGENTS` en `bin/lib/adapters.sh`
3. Ejecuta `fa discover` para poblar el registro

Cada adaptador identifica credenciales, lista modelos (TSV prefijado por agente), e invoca el CLI con las banderas de contención correctas.

## Layout

```
.free-agents/
├── README.md
├── README.es.md               versión en español
├── setup.sh                   hace del directorio padre un proyecto
├── AGENTS.md                  la puerta de enrutamiento que sigue el coordinador
├── prompts/coordinator.md     pega esto en cualquier TUI de agente
├── bin/
│   ├── fa                     punto de entrada único
│   ├── buckets.sh             registro de credenciales: lanes, discover, probe, show
│   ├── run.sh                 motor de envío: fallback, lease, breaker
│   ├── plan.sh                meta -> grafo de tareas
│   ├── orch.sh                grafo de tareas + resumen basado en journal
│   ├── analyze.sh             análisis post-ejecución del journal + aprendizajes
│   └── lib/                   common.sh, deps.sh, adapters.sh, classify.sh
│       └── adapters/          un archivo por agente (opencode, kilo, hermes, copilot, cursor, agy, pi)
├── skills/                    tarjetas de habilidades, enlazadas por `fa bootstrap`
├── state/                     el registro de credenciales (ignorado por git, regenerado)
├── docs/                      SETUP.md, historial de diseño en dev/
└── test/                      CLIs de agente stub + harness, para pruebas offline
```

## Estado

```
~/.local/state/free-agents/buckets.json   billettes + salud   GLOBAL (aprendido)
<proyecto>/.orch/tasks.json               grafo de tareas    POR PROYECTO (comprometido)
<proyecto>/.orch/config.yaml              modo de proyecto   POR PROYECTO (comprometido)
<proyecto>/.orch/journal.ndjson           registro de solo añadir POR PROYECTO
<proyecto>/.orch/results/                 transcripciones de agente POR PROYECTO
<proyecto>/.orch/handoffs/                handoffs de tareas POR PROYECTO
<proyecto>/.orch/worktrees/               worktrees aislados POR PROYECTO (temp)
<proyecto>/.orch/learnings.md             patrones de ejecuciones POR PROYECTO (ignorado por git)
```

## Reproducibilidad

**Reproducible:** la herramienta, la instalación, las reglas de enrutamiento, la taxonomía de errores, y la *forma* de una ejecución.

**No reproducible, por naturaleza:**
- **Salida del modelo.** Modelos gratuitos son no determinísticos; el mismo plan produce código diferente cada ejecución. Las tareas declaran `files` y el corredor las verifica.
- **Qué modelo sirve una tarea.** Depende de la salud de la billetera en vivo. El journal registra qué pasó realmente.
- **El roster de modelos gratuitos.** Proveedores agregan y remueven modelos gratis constantemente. Re-ejecuta `fa discover && fa probe` para auto-sanar.

Un **proyecto** es reproducible: compromete `.orch/tasks.json`, y cualquiera con sus propios carriles puede ejecutar `fa orch run .orch/tasks.json`.

## Pruebas

```sh
bash test/run_all.sh               # 16 suites offline: CLIs de agente stub, registro fixture
bin/lib/classify.sh --self-test    # taxonomía de errores, 28 casos, offline, ~1s
bin/fa doctor                      # deps, CLIs de agente+versiones, presencia, self-test, lanes
bin/fa lanes                       # verificación de humo: >0 significa que las credenciales funcionan
DRY_RUN_LIMIT=0 bin/run.sh --dry-run   # la cadena candidata completa, gasta nada
```

## Documentación

- **`docs/SETUP.md`** — instalación, dónde cada agente esconde sus credenciales, layout completo de archivos
- **`docs/dev/ALIGNMENT.md`** — el diseño y cada hallazgo
- **`docs/dev/SESSION.md`** — estado actual, invariantes, bugs
- **`docs/dev/RUN-*.md`** — registros de ejecuciones reales de proyectos

## Peligros

Estos CLIs **salen 0 en fallos duros** (hermes devuelve 0 en HTTP 404 y en una facturación rechazada). Clasifica por salida, nunca por código de salida.
- **La contención difiere por agente**: `opencode --dir`, `kilo --dir`, y hermes vía `HOME`.
- Una ruta es `(agente, modelo, **proveedor**)`. `hermes -m X` se resuelve contra su *activo* proveedor solamente.
- Un modelo aún puede escribir a una ruta absoluta sin importar cualquier bandera. **Verifica los archivos.**
- **El campo `free` en la salida del adaptador debe ser literal `true` o `false`** — el analizador en `buckets.sh` verifica `(.[4]==\"true\")`, no una etiqueta libre como `"free"`.
- **Mantén el formato TSV estricto**: 7 campos separados por tabulaciones para modelos (`agente proveedor model_arg upstream free context max_output`), 6 para identidades (`agente proveedor billetera ident source extra`). Cualquier nueva línea literal en el campo `extra` rompe el constructor de registros.

---

[English](README.md) | [Español](README.es.md)
