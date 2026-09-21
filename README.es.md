# free-agents-free-models

Haz trabajo real de programación con **modelos gratuitos** a través de múltiples agentes CLI (opencode, kilo, hermes, copilot, cursor, agy, pi) sin que un límite de tasa te detenga nunca, y sin que dos trabajadores compitan por la misma clave API.

[English](README.md) | [Español](README.es.md)

## ¿Qué es?

Una capa de planificación que convierte modelos de IA gratuitos en líneas de construcción paralelas. La idea central: **un bucket es una billetera — un par `(proveedor, credencial)` — y la billetera es la unidad de límite de tasa, por lo tanto la unidad de planificación.**

Dale a cada agente una clave API gratuita diferente, y obtienes más carriles. opencode, kilo y hermes incluyen sus propios modelos gratuitos, y cada uno acepta claves de puerta de enlace adicionales. Cada credencial distinta es una cuota independiente que puedes ejecutar en paralelo.

La unidad de planificación es la **credencial**, no el agente:
- **Claves diferentes → verdadero paralelismo.** Dos agentes con claves diferentes son dos carriles incluso ejecutando el mismo modelo.
- **La misma clave en dos agentes es UN SOLO carril.** Ejecutar ambos no va más rápido — compite contra sí mismo por el límite de esa clave. La herramienta lo detecta automáticamente y lo marca como una billetera compartida.

## Entorno

**Linux y macOS** funcionan de forma nativa. **Windows requiere WSL2** — todos los agentes (opencode, kilo, hermes, pi, copilot, cursor, agy) deben instalarse dentro del entorno WSL, y `.free-agents` se ejecuta desde allí. La herramienta es shell pura — no existe una versión nativa para Windows.

Dentro de WSL:
- Usa una distribución Ubuntu o Debian
- Instala Node.js 18+ y Python 3.11+
- Todos los agentes van en `/usr/local/nodejs/bin/` o `~/.local/bin/`
- El registro en `~/.local/state/free-agents` es nativo de WSL

Puedes lanzar ejecuciones desde PowerShell de Windows o VS Code Remote — pero los agentes y el binario `fa` viven en Linux.

## Cómo funciona

Trabajas dentro del TUI de un agente como siempre. La diferencia es que el agente tiene acceso a carriles paralelos y decide cuándo usarlos.

### Paso 1: Abre tu TUI

Abre cualquier agente soportado (opencode, kilo, hermes, pi, agy, copilot, cursor). Usa tmux o herdr para ver múltiples ventanas a la vez — esta es la configuración recomendada porque verás a los trabajadores lanzarse en sus propias ventanas.

### Paso 2: Pega el prompt del coordinador

Pega `.free-agents/prompts/coordinator.md` en el TUI al inicio de una sesión. El agente lo lee, ejecuta `fa doctor` para verificar la máquina, y desde ese momento es el coordinador — decide qué construir, cuándo dividir el trabajo, y cómo enviarlo.

### Paso 3: Trabaja normalmente

Háblale al agente. Pídele que construya algo, investigue algo, arregle algo. El agente elige el modo:
- **Tarea pequeña** → la hace directamente en tu TUI
- **Construcción de múltiples partes** → planifica, envía trabajadores a través de tus carriles, los monitorea

### Paso 4: Monitorea (opcional)

Abre otra terminal y ejecuta `fa status` para ver qué está corriendo. En tmux/herdr verás ventanas de trabajadores aparecer y desaparecer según se usen los carriles.

Cuando termina, el coordinador imprime un reporte de salida: archivos cambiados, estado de verificación, trabajo restante.

## Guía Visual

### 1. ¿Qué es un carril?

Un carril es una billetera — un par `(proveedor, credencial)`. La billetera es la unidad de límite de tasa, por lo tanto la unidad de planificación.

```
┌─────────────────────────────────────────────────────────────┐
│  CARRIL = una billetera = un par (proveedor, credencial)   │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐  │
│  │  Credencial  │    │   Modelos    │    │    Salud     │  │
│  │              │    │              │    │              │  │
│  │  proveedor:  │───▶│  modelo_a    │    │  estado: ok  │  │
│  │  openrouter  │    │  modelo_b    │    │  fallos: 0   │  │
│  │  fp: 845a..  │    │  modelo_c    │    │  enfriam.: - │  │
│  └──────────────┘    └──────────────┘    └──────────────┘  │
│                                                             │
│  Claves diferentes = carriles diferentes = verdadero paralelismo  │
│  Misma clave en dos agentes = UN SOLO carril = compiten │
└─────────────────────────────────────────────────────────────┘
```

#### Colapso de credencial

```
  hermes ──▶ nous:9162a7f63a81 ──┐
                                 ├──▶ MISMO CARRIL (una billetera)
  opencode ──▶ nous:9162a7f63a81 ─┘

  opencode ──▶ openrouter:845a3f963b8a ──┐
                                          ├──▶ CARRILES DIFERENTES (paralelo)
  pi ──▶ openrouter:131083dc00f2 ────────┘
```

### 2. ¿Qué pasa cuando ejecutas una tarea?

```
  ┌─────────┐
  │  fa run │
  │ "tarea" │
  └────┬────┘
       │
       ▼
  ┌──────────────┐     ┌──────────────┐
  │  PLANIFICAR  │────▶│  Auto-       │
  │  meta→spec   │     │  contenido   │
  └──────┬───────┘     │  tarea spec  │
         │             └──────────────┘
         ▼
  ┌──────────────┐
  │  ENVIAR      │
  │  elegir carril│
  └──────┬───────┘
         │
         ▼
  ┌──────────────┐     ┌──────────────┐
  │  INVOCAR     │────▶│  El agente   │
  │  agente+model│     │  ejecuta     │
  └──────┬───────┘     └──────────────┘
         │
         ▼
  ┌──────────────┐
  │  CLASIFICAR  │
  │  salida      │
  └──────┬───────┘
         │
    ┌────┴────┐
    │         │
    ▼         ▼
┌───────┐ ┌───────┐
│  OK   │ │ FALLO │
└───┬───┘ └───┬───┘
    │         │
    │         ▼
    │    ┌──────────┐     ┌──────────────┐
    │    │  REINTENTO│────▶│  Mismo carril│
    │    │  mismo    │     │  mismo modelo│
    │    └────┬─────┘     └──────────────┘
    │         │
    │    ┌────┴────┐
    │    │         │
    │    ▼         ▼
    │ ┌───────┐ ┌──────────┐
    │ │  OK   │ │ AGOTADO  │
    │ └───────┘ └────┬─────┘
    │                │
    │                ▼
    │         ┌──────────────┐
    │         │  ALTERNATIVA │
    │         │  sig. carril │
    │         └──────┬───────┘
    │                │
    │           ┌────┴────┐
    │           │         │
    │           ▼         ▼
    │        ┌───────┐ ┌───────┐
    │        │  OK   │ │ FALLO │──▶ disyuntor
    │        └───────┘ └───────┘    (billetera enfriada)
    │
    ▼
┌──────────┐
│  LISTO   │
│  reporte │
└──────────┘
```

### 3. ¿Cómo piensa el coordinador?

```
                    ┌─────────────────┐
                    │  fa orch run    │
                    │  tareas.json    │
                    └────────┬────────┘
                             │
                             ▼
                    ┌─────────────────┐
                    │  ¿Se divide?    │
                    │  ≥2 tareas,     │
                    │  archivos disj. │
                    └────────┬────────┘
                             │
                    ┌────────┴────────┐
                    │                 │
                   SÍ               NO
                    │                 │
                    ▼                 ▼
           ┌───────────────┐  ┌───────────────┐
           │  Carriles ≥ 2?│  │  TRABAJO      │
           │  fa lanes -v  │  │  DIRECTO      │
           └───────┬───────┘  │  (1 tarea)    │
                   │          └───────────────┘
           ┌───────┴───────┐
           │               │
          SÍ              NO
           │               │
           ▼               ▼
    ┌──────────────┐  ┌──────────────┐
    │  ENVIAR      │  │  TRABAJO     │
    │  paralelo    │  │  DIRECTO     │
    │  + aislamiento│ │  (1 carril)  │
    └──────┬───────┘  └──────────────┘
           │
           ▼
    ┌──────────────┐
    │  POR TAREA:  │
    │  elegir      │
    │  por ranking │
    │  + salud     │
    └──────┬───────┘
           │
           ▼
    ┌──────────────┐
    │  EJECUTAR    │
    │  agente +    │
    │  modelo      │
    └──────┬───────┘
           │
           ▼
    ┌──────────────┐
    │  VERIFICAR   │
    │  arch. existen│
    │  tests pasan │
    └──────┬───────┘
           │
    ┌──────┴──────┐
    │             │
  FALLO        OK
    │             │
    ▼             ▼
  ┌──────┐   ┌──────────┐
  │REINT.│   │  FUNDIR  │
  │o ALT.│   │  worktree│
  └──────┘   │  reporte │
             └──────────┘
```

### 4. Escenario: "Construir un dashboard React"

Con el estado real del registro (8 carriles, 163 modelos gratis):

```
┌─────────────────────────────────────────────────────────────────┐
│  REGISTRO: 8 carriles, 163 modelos gratis                      │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  antigravity:67da9cad9d70  ── agy        14 gratis (Gemini/Claude)│
│  opencode:zen             ── opencode    4 gratis (hospedado)   │
│  openrouter:845a3f963b8a  ── opencode   27 gratis (clave OR 1)  │
│  openrouter:131083dc00f2  ── pi         86 gratis (clave OR 2)  │
│  kilo:anon                ── kilo       23 gratis (sin clave)   │
│  nous:6b7db10dba77        ── hermes      7 gratis (clave Nous)  │
│  copilot:bbc7cfd0e9b0     ── copilot     1 (medido, último)     │
│  cursor:eca81fa11190      ── cursor      1 (medido, último)     │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

ESCENARIO: "Construir un dashboard React con tests"

┌─────────────────────────────────────────────────────────────────┐
│  PASO 1: PLANIFICAR                                             │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐             │
│  │ Tarea A: API│  │ Tarea B: UI │  │ Tarea C:Tests│            │
│  │ src/api.js  │  │ src/components│ │ src/tests/  │            │
│  │ deps: []    │  │ deps: [A]   │  │ deps: [A,B] │             │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘             │
│         │                │                │                     │
│         ▼                ▼                ▼                     │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  PASO 2: ENVIAR (paralelo donde sea posible)            │   │
│  │                                                         │   │
│  │  Tarea A ──▶ openrouter:131083dc00f2 (pi, 86 modelos)  │   │
│  │  Tarea B ──▶ opencode:zen (hospedado, sin credencial)  │   │
│  │  Tarea C ──▶ kilo:anon (23 modelos, sin clave)        │   │
│  │                                                         │   │
│  │  Las tres se ejecutan SIMULTÁNEAMENTE en billeteras    │   │
│  │  independientes                                         │   │
│  └─────────────────────────────────────────────────────────┘   │
│         │                                                       │
│         ▼                                                       │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  PASO 3: EJECUTAR                                       │   │
│  │                                                         │   │
│  │  pi ejecuta api.js ──────────────▶ ✓ éxito              │   │
│  │  opencode ejecuta components ────▶ ✓ éxito              │   │
│  │  kilo ejecuta tests ─────────────▶ ✗ fallo              │   │
│  │       │                                                 │   │
│  │       └──▶ ALTERNATIVA: nous:6b7db10dba77              │   │
│  │           hermes ejecuta tests ──▶ ✓ éxito              │   │
│  └─────────────────────────────────────────────────────────┘   │
│         │                                                       │
│         ▼                                                       │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  PASO 4: VERIFICAR Y REPORTAR                           │   │
│  │                                                         │   │
│  │  ✓ api.js existe, sintaxis OK                           │   │
│  │  ✓ components/ existe, sintaxis OK                      │   │
│  │  ✓ tests/ existe, sintaxis OK                           │   │
│  │                                                         │   │
│  │  Archivos cambiados: 12                                 │   │
│  │  Verificación: todo pasa                                │   │
│  │  Trabajo restante: ninguno                              │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 5. Manejo de fallos: "Mantener todo corriendo pase lo que pase"

```
┌─────────────────────────────────────────────────────────────────┐
│  MODOS DE FALLO Y RESPUESTAS                                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. MODELO DEVUELVE BASURA                                     │
│     ┌──────────┐    ┌──────────┐    ┌──────────┐              │
│     │ clasificar│───▶│ REINTENTO│───▶│ mismo    │              │
│     │ = suave  │    │ mismo    │    │ carril   │              │
│     └──────────┘    │ carril   │    └──────────┘              │
│                     └──────────┘                                │
│                                                                 │
│  2. LÍMITE DE TASA (429)                                       │
│     ┌──────────┐    ┌──────────┐    ┌──────────┐              │
│     │ clasificar│───▶│ALTERNA-  │───▶│siguiente │              │
│     │ = 429    │    │TIVA      │    │sano      │              │
│     └──────────┘    │sig. carril│   └──────────┘              │
│                     └──────────┘                                │
│                                                                 │
│  3. CREDENCIAL MUERTA (401, facturación)                       │
│     ┌──────────┐    ┌──────────┐    ┌──────────┐              │
│     │ clasificar│───▶│ALTERNA-  │───▶│siguiente │              │
│     │ = auth   │    │TIVA      │    │carril    │              │
│     └──────────┘    │saltar    │    └──────────┘              │
│                     └──────────┘                                │
│                                                                 │
│  4. FALLOS CONSECUTIVOS                                        │
│     ┌──────────┐    ┌──────────┐    ┌──────────┐              │
│     │ 3 fallos │───▶│DISYUNTOR │───▶│CONGELAR  │              │
│     │ seguidos │    │          │    │billetera │              │
│     └──────────┘    └──────────┘    │ 15 min   │              │
│                                     └──────────┘              │
│                                                                 │
│  5. TODOS LOS CARRILES AGOTADOS                                │
│     ┌──────────┐    ┌──────────┐                               │
│     │ no hay   │───▶│ TAREA    │                               │
│     │ sanos    │    │ FALLA    │                               │
│     └──────────┘    └──────────┘                               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 6. Carriles medidos: cuándo se usan

```
┌─────────────────────────────────────────────────────────────────┐
│  ORDEN DE SELECCIÓN DE CARRILES (modo auto)                    │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. Carriles gratis (ilimitados)                                │
│     ┌─────────────────────────────────────────────────────┐    │
│     │  kilo:anon, opencode:zen, openrouter:*, nous:*,     │    │
│     │  antigravity:*, pi:*                                │    │
│     └─────────────────────────────────────────────────────┘    │
│                                                                 │
│  2. Carriles medidos (agotables)                                │
│     ┌─────────────────────────────────────────────────────┐    │
│     │  copilot:bbc7cfd0e9b0 (200 créditos, renueva oct 1)│    │
│     │  cursor:eca81fa11190 (medido)                      │    │
│     └─────────────────────────────────────────────────────┘    │
│                                                                 │
│  Los carriles medidos se intentan ÚLTIMOS, solo cuando todos    │
│  los gratis están ocupados, fríos o agotados. No pueden         │
│  facturarte — se detienen cuando se acaban los créditos y       │
│  renuevan mensualmente.                                         │
│                                                                 │
│  --no-metered  → omitir paso 2 completamente                  │
│  --allow-metered → forzar paso 2 aunque haya gratis disponibles│
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Configuración (una vez)

```sh
cd mi-proyecto
gh repo clone rcsoftinc/free-agents-free-models .free-agents
.free-agents/setup.sh
.free-agents/bin/fa bootstrap          # descubrir credenciales, instalar habilidades
.free-agents/bin/fa lanes -v           # ver tus carriles
```

### Auto-instalación

`setup.sh` verifica las dependencias del sistema (jq, curl, flock, sqlite3, timeout)
y los CLIs de agente faltantes (opencode, kilo, hermes, copilot, cursor, agy, pi),
luego pregunta si desea instalarlos. Use `FA_AUTO_INSTALL=1` para omitir las preguntas:

```sh
FA_AUTO_INSTALL=1 .free-agents/setup.sh
```

### Credenciales en una máquina nueva

Instalar los CLIs no es lo mismo que iniciar sesión en ellos. `setup.sh`
también maneja las credenciales, en dos niveles:

- **opencode, kilo, pi** no necesitan más que una clave de API en texto
  plano. Copia `keys.env.example` a `keys.env` (ignorado por git), pega una
  clave de OpenRouter **diferente** en cada línea que quieras usar — la
  misma clave dos veces es una sola billetera, no dos — y `setup.sh` escribe
  cada una directamente en el archivo de configuración propio de ese agente.
  Sin `keys.env`, no hay problema: este paso es un no-op silencioso.
- **copilot, cursor, agy, hermes** necesitan un inicio de sesión real de
  cuenta, algo que nada puede hacer de forma segura en tu nombre. `setup.sh`
  detecta quién ya inició sesión, ofrece el paso de login de cada uno de los
  restantes de forma interactiva, y al final imprime un resumen de toda
  cuenta que sigue sin iniciar sesión — así un login que nadie completó
  queda reportado, no silenciosamente omitido.

Detalle completo, incluyendo el archivo exacto donde vive cada credencial y
por qué algunos de los comandos de login guiado están marcados como
"adivinanza sin verificar": `docs/SETUP.md`.

### Primera ejecución

Inicia tu agente preferido (opencode, kilo, hermes, pi, agy, copilot, cursor) y pásale el prompt del coordinator:

```
.free-agents/prompts/coordinator.md
```

El agente lo lee, ejecuta `fa doctor`, y se convierte en el coordinador — decide qué construir, cuándo dividir el trabajo y cómo despachar a través de tus carriles.

Cada agente aporta algo diferente más allá de su herramienta — diferente acceso a modelos, diferente semántica de contención, diferentes modos de fallo. Esto es lo que cada uno añade a tu grupo:

### opencode

Dos billeteras distintas. Primero, **modelos zen** — hospedados por opencode mismo, sin credencial necesaria, 4 modelos gratis (zen). Segundo, cualquier clave OpenRouter que configures, dándote acceso a 200+ modelos comunitarios. Opencode usa `--dir` para contención (aislamiento de proceso real), lo que lo convierte en uno de los carriles más seguros para trabajo paralelo. Su lista de modelos incluye tamaño de contexto y salida máxima, para que el planificador pueda emparejar la complejidad de la tarea con la capacidad del modelo.

### kilo

El **grupo no autenticado más grande** — 23 modelos gratis sin necesidad de clave. También acepta claves OpenRouter vía `kilo.jsonc`, así que puedes apilarlo con una clave diferente a la de opencode para duplicar tus carriles OpenRouter. Kilo usa `--dir` para contención. Sus modelos incluyen modalidad de salida (texto, audio, etc.), lo que ayuda al planificador a evitar enviar tareas de texto a modelos de audio. Cuidado: puede ser verboso — clasifica por patrones de salida, no por código de salida.

### hermes

El **generalista multi-proveedor**. Alcanza Nous, Kilo gateway, OpenRouter, y otros a través de un solo CLI — cada uno se convierte en un carril separado. Hermes es el único agente que lee señales gratis específicas del gateway (isFree, precio cero, sufijo `:free`), por lo que descubre modelos que otros pasan por alto. La contención es diferente: ignora `--dir`, así que fa usa redirección de `HOME` en su lugar. Sus tokens OAuth rotan cada hora — el registro huella digital del sujeto estable, no el token.

### pi

El **carril de alto volumen**. Pi respaldado por OpenRouter te da 353 modelos (86 gratis), haciéndolo el bucket individual más grande. Es un trabajador de propósito general fuerte: contención `--add-dir`, invocación directa `--model` + `--print`, catálogo OpenRouter estándar con tamaños de contexto claros. El volumen puro significa que cuando otros carriles están ocupados o fríos, pi casi siempre tiene capacidad. Cuidado: pi no publica sufijos `:free` — el adaptador detecta variantes `:free` y `:batch`.

### agy (Antigravity)

El **carril de calidad Google** con 14 modelos gratis (Gemini, Claude, GPT-OSS). Usa Google OAuth — el adaptador huella digital del token de actualización (estable) así que la rotación de tokens no crea carriles duplicados. Usa `--add-dir` para contención. Útil cuando quieres modelos del ecosistema de Google sin manejar una clave API directamente. La bandera `--print` lo hace no interactivo y amigable con scripts.

### copilot

La **red de seguridad medida**. 200 créditos mensuales, renuevan mensualmente, `overage_permitted: false` — se detiene en lugar de facturar. Auto-enrutado (sin selector de modelo, un bucket con "auto"). Intentado último por defecto, solo cuando todos los carriles gratis están ocupados o fríos. Usa `--allow-all` + `--add-dir` para contención. Su fortaleza no es volumen sino fiabilidad — los modelos de GitHub tienden a ser bien probados y actualizados.

### cursor

El **segundo carril medido**, similar a copilot: auto-enrutado, asignación mensual agotable, intentado último. Reporta email de cuenta vía `cursor-agent status`. Usa `-f` para confiar en el directorio (se niega a ejecutar headless de otra manera). Como copilot, su valor es como fallback cuando los carriles gratis están agotados — no como trabajador principal.

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
- **La categoría importa** — las tareas declaran una categoría (`coding`, `reasoning`, `research`, `general`, `fast`). El planificador rastrea qué modelos tienen éxito por categoría y clasifica las elecciones futuras acordemente. Un modelo bueno para coding puede ser malo para investigación — la categoría mantiene esa señal separada.
- **La complejidad es contexto opcional, no una puerta (todavía)** — una tarea puede declarar `"complexity": "trivial" | "standard" | "substantial"`. `fa dispatch` la muestra (una pista cuando todas las tareas de un lote son triviales) pero aún no ramifica según ella; un modo real de envío por lotes para agrupar tareas triviales en un solo carril está en el roadmap, no construido.

### Trabajo que espera

Algunas tareas no pueden hacerse aún: necesitan credenciales que no tienes, un servicio que no está provisionado, o una decisión que solo tú puedes hacer. Márcalas con un campo `blocked` — nunca se envían, nunca se cuentan como fallos, y cualquier cosa que dependa de ellas espera con ellas. Cuando las desbloqueas, `fa resume` las recoge. El coordinador debería preguntar antes de asumir que algo está bloqueado.

### Handoffs

Las tareas que tienen dependientes pasan contexto hacia adelante mediante un bloque estructurado al final de su salida:

```
---HANDOFF---
decisions: <qué elegiste y por qué>
rejected: <alternativas consideradas y por qué fueron rechazadas>
open: <preguntas o decisiones que la siguiente tarea debe tomar>
```

Este bloque se da a las tareas que declararon esta como dependencia. Si una tarea no escribe nada, su dependiente recibe una línea fija de advertencia en vez de un vacío silencioso — "no se proveyó handoff, verifica la salida de esta dependencia directamente".

El handoff **no** es un resumen — no hay llamada de modelo extra, no se gasta un carril. El trabajador ya está generando salida; solo estructuramos su final.

Una tarea puede añadir una línea más — `result: <JSON de una línea>` — pero solo cuando algo río abajo realmente la necesita: una tarea dependiente que declare `"when": {"dep": "api", "path": ".decision", "equals": "yes"}` en su propia especificación solo pedirá esa línea, y solo correrá si el valor coincide. Un `when` insatisfecho **omite** la tarea (no es un fallo — cualquier cosa que dependa de la tarea omitida sigue su curso normal).

### Categorías de trabajo

El campo `category` en una tarea no es cosmético — maneja la selección de modelo:

| Categoría | Mejor para | Qué aprende el planificador |
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

Se configura editando `.orch/config.yaml` directamente (no existe un comando `fa config`). **Nota de honestidad:** hoy `mode` y `automerge` se leen pero todavía no cambian el comportamiento del envío según el modo — toda tarea pasa por el mismo ciclo de worktree-aislado-y-commit-de-fusión sin importar qué modo esté configurado. Trata esta tabla como la intención documentada de hacia dónde va la autonomía por proyecto, no como comportamiento ya exigido.

## Cómo se clasifican modelos y agentes

Cada envío recorre una cadena clasificada de candidatos `(billetera, modelo, agente)` —
qué billetera, qué modelo y a través de qué CLI enrutarlo. Nada está fijado de
antemano; todo se aprende de lo que realmente ha funcionado, por separado para
cada categoría de tarea, en dos ejes independientes:

**Clasificación de modelos.** Conteos de éxito/fallo por categoría, así un modelo
bueno en `coding` nunca se asume bueno en `reasoning`. Un modelo sin historial
todavía en una categoría cae de vuelta a una estimación de arranque en frío —
tamaño de contexto, un par de heurísticas de nombre, y una opinión semilla
opcional que puedes editar a mano o generar a partir de un leaderboard en
`data/model-seed.json` (ver su propia clave `_README` para el formato,
incluyendo overrides por categoría). En el momento en que existe evidencia real
para esa categoría, gana sin discusión — la estimación nunca vuelve a competir
con ella.

**Clasificación de agente/contenedor.** El mismo modelo, alcanzable a través de
dos CLIs distintos en una billetera (digamos, tanto opencode como kilo tienen
la misma clave de OpenRouter), también se clasifica entre ellos — y si el
contenedor mejor clasificado empieza a fallar, el siguiente intento cae
automáticamente al otro contenedor sobre la **misma** billetera y modelo,
antes de siquiera intentar un modelo o una billetera diferente.

Mira lo que la herramienta ha aprendido, sin gastar una petición:

```sh
fa rank coding      # la cadena completa de candidatos clasificados para una categoría
fa profile          # tasa de éxito por agente/contenedor, aprendida de ejecuciones reales
```

Y si una meta de varias partes vale la pena dividirla entre carriles —
en lugar de que tú (o el agente) lo adivinen — es en sí misma una verificación
mecánica:

```sh
fa dispatch "meta"  # planifica, y luego imprime su decisión DIRECT vs ORCHESTRATE
fa dispatch         # el mismo chequeo, contra un grafo de tareas que ya escribiste
```

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
| **Clasificación de agente/contenedor** | Aprende qué CLI realmente obtiene resultados por categoría, y cae al siguiente mejor contenedor sobre la misma billetera y modelo antes de intentar cualquier otra cosa (`fa profile`) |
| **Disyuntor de bucket** | Congela una billetera después de fallos consecutivos, omite todos sus modelos instantáneamente |
| **`fa dispatch`** | La decisión orquestar-vs-directo como código real, no una regla que un coordinador tiene que calcular bien a mano — imprime su evaluación, envía cuando decide hacerlo |
| **`fa rank`** | Vista de solo lectura de la cadena de candidatos clasificados para una categoría — ve por qué se eligió un modelo/agente, sin gastar una petición |
| **Visualización de grafo** | Renderiza el grafo de tareas como diagrama ASCII (`fa graph`, `fa plan --graph`) — verifica la división antes de gastar tokens |
| **Bordes condicionales `when`** | Una tarea puede correr solo si el resultado reportado de una dependencia completada coincide — una rama real en el grafo de tareas, no solo una espera |
| **Resumen a prueba de caídas** | Registro de solo añadir; resume cualquier ejecución después de una interrupción, sin reenviar una tarea cuyo proceso hijo de una ejecución matada sigue vivo |
| **Carriles medidos** | Auto-incluye copilot/cursor cuando se detectan con créditos, intentados últimos |
| **Puerta de verificación** | Verificación de sintaxis post-construcción opcional con bucle de auto-arreglo (`--validate`) |
| **Modos de proyecto** | Autonomía por proyecto: strict (default), push, local — ver la nota de honestidad arriba de la tabla de modos |
| **Handoffs** | Bloque estructurado (decisions, rejected, open) pasado a dependientes; sin llamada de modelo extra. Una dependencia que no deja handoff hace que se inyecte una advertencia suave en el prompt de su dependiente, en vez de un vacío silencioso |
| **Findings** | Registra lo que la herramienta notó que manejó mal; copiable a issues |

## Capacidades

Cada agente declara lo que puede hacer. El planificador empareja los requisitos de la tarea con las capacidades del agente:

| Agente | Capacidades |
|-------|-------------|
| **opencode** | `code,reasoning,shell,git,file` |
| **kilo** | `code,reasoning,shell,git,file` |
| **hermes** | `web,browser,code,research,reasoning,shell,git,file` |
| **copilot** | `code,reasoning,shell,git,file` |
| **cursor** | `web,code,reasoning,shell,git,file` |
| **agy** | `web,code,research,reasoning,file` |
| **pi** | `code,reasoning,file` |

### Categoría → Capacidades Requeridas

| Categoría | Requerida | Agentes elegibles |
|-----------|----------|-----------------|
| **coding** | `code` | todos |
| **research** | `web` OR `research` | hermes, cursor, agy |
| **reasoning** | `reasoning` | todos |
| **fast** | `code` | todos |
| **general** | `code` | todos |

## Bootstrap (una vez por máquina)

```sh
fa bootstrap    # descubrir credenciales, probar billeteras, instalar habilidades
fa doctor       # verificar la máquina
fa lanes -v     # con lo que terminaste
```

`bootstrap` lee las credenciales que tus agentes ya poseen — nunca pide claves y nunca almacena una. El registro es **global a la máquina** en `~/.local/state/free-agents`. Un bootstrap sirve para cada proyecto en la caja.

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
├── keys.env.example           plantilla para configuración de claves no interactiva (opcional)
├── AGENTS.md                  la puerta de enrutamiento que sigue el coordinador
├── prompts/coordinator.md     pega esto en cualquier TUI de agente
├── bin/
│   ├── fa                     punto de entrada único
│   ├── buckets.sh             registro de credenciales: lanes, discover, probe, show
│   ├── run.sh                 motor de envío: fallback, lease, breaker
│   ├── plan.sh                meta -> grafo de tareas
│   ├── orch.sh                grafo de tareas + resumen basado en journal
│   ├── analyze.sh             análisis post-ejecución del journal + aprendizajes
│   └── lib/                   common.sh, deps.sh, adapters.sh, classify.sh, keys.sh
│       └── adapters/          un archivo por agente (opencode, kilo, hermes, copilot, cursor, agy, pi)
├── data/model-seed.json       opinión OPCIONAL de arranque en frío - edítala a mano o
│                               genérala de un leaderboard; bórrala y nada se rompe (ver su
│                               propia clave "_README" para el formato)
├── skills/                    tarjetas de habilidades, enlazadas por `fa bootstrap`
├── state/                     el registro de credenciales (ignorado por git, regenerado)
├── docs/                      SETUP.md, historial de diseño en dev/
└── test/                      CLIs de agente stub + harness, para pruebas offline
```

## Estado

```
~/.local/state/free-agents/buckets.json   billeteras + salud   GLOBAL (aprendido)
<proyecto>/.orch/tasks.json               grafo de tareas    POR PROYECTO (confirmado)
<proyecto>/.orch/config.yaml              modo de proyecto   POR PROYECTO (confirmado)
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

Un **proyecto** es reproducible: confirma `.orch/tasks.json`, y cualquiera con sus propios carriles puede ejecutar `fa orch run .orch/tasks.json`.

## Pruebas

```sh
bash test/run_all.sh               # 24 suites offline: CLIs de agente stub, registro fixture
bin/lib/classify.sh --self-test    # taxonomía de errores, 43 casos, offline, ~1s
bin/fa doctor                      # deps, CLIs de agente+versiones, presencia, self-test, lanes
bin/fa lanes                       # verificación de humo: >0 significa que las credenciales funcionan
DRY_RUN_LIMIT=0 bin/run.sh --dry-run   # la cadena candidata completa, gasta nada
```

## Documentación

- **`docs/SETUP.md`** — instalación, dónde cada agente esconde sus credenciales, layout completo de archivos
- **`docs/dev/PARADIGMS.md`** — paradigmas de flujo de trabajo multi-agente: framework Grafo/Bucle/Contenedor, cobertura de fa, brechas y roadmap priorizado
- **`docs/dev/ALIGNMENT.md`** — el diseño y cada hallazgo
- **`docs/dev/SESSION.md`** — estado actual, invariantes, bugs
- **`docs/dev/RUN-*.md`** — registros de ejecuciones reales de proyectos

## Peligros

Estos CLIs **salen 0 en fallos duros** (hermes devuelve 0 en HTTP 404 y en un rechazo de facturación). Clasifica por salida, nunca por código de salida.
- **La contención difiere por agente**: `opencode --dir`, `kilo --dir`, y hermes vía `HOME`.
- Una ruta es `(agente, modelo, **proveedor**)`. `hermes -m X` se resuelve contra su proveedor *activo* solamente.
- Un modelo aún puede escribir a una ruta absoluta sin importar cualquier bandera. **Verifica los archivos.**
- **El campo `free` en la salida del adaptador debe ser literal `true` o `false`** — el analizador en `buckets.sh` verifica `(.[4]==\"true\")`, no una etiqueta libre como `"free"`.
- **Mantén el formato TSV estricto**: 7 campos separados por tabulaciones para modelos (`agente proveedor model_arg upstream free context max_output`), 6 para identidades (`agente proveedor billetera ident source extra`). Cualquier nueva línea literal en el campo `extra` rompe el constructor de registros.
- **Un `when.dep` también debe estar listado en el propio `deps` de esa tarea.** `when` solo decide si correr una vez que su dependencia ya terminó; sin la entrada `deps` correspondiente, la tarea podría volverse elegible antes de que esa dependencia llegue a correr. `fa plan`/`check_graph_integrity` rechazan un plan que se equivoca en esto, pero un `tasks.json` editado a mano no se detecta hasta el envío.
- **`fa dispatch`/`fa go` sin meta lee el `tasks.json` que ya está en disco** — nunca vuelve a planificar si ya existe uno. Pasa una meta explícitamente (`fa dispatch "meta"`) cuando quieras un plan nuevo en vez de evaluar lo que ya está ahí.
