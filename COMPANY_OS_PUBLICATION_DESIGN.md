# TwinVault → Company OS: diseño de publicación selectiva

**Estado:** propuesta técnica; no implementada  
**Ámbito:** contrato futuro entre TwinVault y Company OS  
**Fuera de alcance:** sincronización, cliente de red, credenciales, cambios en Company OS Core, PostgreSQL o almacenamiento local

## 1. Decisión arquitectónica

TwinVault seguirá siendo la fuente local de las grabaciones y de su evidencia técnica. Company OS podrá recibir una copia explícitamente autorizada de una versión concreta de una reunión, pero no tendrá acceso directo al vault, a SQLite ni al sistema de archivos del Mac.

La integración futura será un adaptador HTTPS autenticado detrás de un protocolo de dominio reemplazable. El adaptador construirá un manifiesto inmutable a partir de un estado local revisado y lo enviará a una API de Company OS. Ningún endpoint descrito en este documento se considera existente hasta que Company OS lo apruebe e implemente.

```text
TwinVault local
┌──────────────────────────────────────────────────────────────┐
│ Meeting + audio refs + transcript versions + corrections     │
│             │                                                │
│             ▼                                                │
│ Evidence Health Check ──► Human review snapshot              │
│             │                       │                        │
│             └──────────────┬────────┘                        │
│                            ▼                                 │
│ Target and content selection + explicit authorization        │
│                            │                                 │
│                            ▼                                 │
│ Versioned publication manifest + durable local attempt       │
└────────────────────────────┬─────────────────────────────────┘
                             │ TLS + authenticated API
                             ▼
Company OS API boundary
┌──────────────────────────────────────────────────────────────┐
│ Authorization + workspace policy + idempotency               │
│ Canonical meeting + target associations + transcript version │
│ Publication receipt + audit + derivative invalidation hooks  │
└──────────────────────────────────────────────────────────────┘
```

Principios:

- publicación iniciada siempre por una acción humana;
- selección explícita de destino y contenido;
- metadatos y transcripción antes que audio;
- identidad local estable y procedencia conservada;
- reintentos idempotentes, nunca duplicación silenciosa;
- respuestas de Company OS tratadas como confirmaciones externas, no como cambios de la evidencia local;
- ninguna escritura directa en PostgreSQL;
- ningún secreto en el repositorio, `UserDefaults`, manifiestos o logs.

## 2. Flujo de publicación

### 2.1 Estados conceptuales

```text
LOCAL_ONLY
   │ Run Health Check
   ▼
HEALTH_CHECKED
   │ review exact content snapshot
   ▼
REVIEWED
   │ choose workspace + zero or more companies/projects
   ▼
TARGETED
   │ choose fields + preview + authorize
   ▼
AUTHORIZED
   │ persist operation and send/retry same idempotency key
   ▼
SUBMITTED ───────────► CONFIRMED
   │                       │
   ├── retryable error     └── later correction/new snapshot
   ▼                                   │
RETRY_PENDING                         ▼
   │                              SUPERSEDED
   └──────────────► SUBMITTED

Terminal/manual states: FAILED, CANCELLED, REQUIRES_REVIEW
```

Estos estados describen el incremento futuro; no se añaden ahora al modelo local.

### 2.2 Condiciones de elegibilidad propuestas

Antes de habilitar **Publish to Company OS**:

1. La reunión está completada.
2. Un Health Check reciente no contiene errores. Las advertencias requieren reconocimiento explícito.
3. La transcripción seleccionada tiene estado `reviewed`.
4. Existe una instantánea de revisión que identifica exactamente:
   - `transcriptionID` y número de versión;
   - IDs de segmentos y contenido original;
   - IDs de correcciones incluidas;
   - digest del texto efectivo revisado.
5. El usuario está autenticado y Company OS confirma acceso al workspace destino.
6. Todos los destinos seleccionados se han resuelto por ID canónico, nunca por nombre.
7. El usuario ve una previsualización de los campos que saldrán del dispositivo y confirma la publicación.

El punto 4 no existe aún como una atestación única en TwinVault. El futuro incremento deberá introducir un `ReviewAttestation` local antes de enviar datos. Marcar una versión como revisada, por sí solo, no debe certificar correcciones realizadas después.

### 2.3 Selección de destino

Una publicación tendrá exactamente un workspace de Company OS y podrá tener múltiples asociaciones:

- ninguna, una o varias empresas;
- ninguno, uno o varios proyectos;
- una reunión canónica creada o vinculada;
- participantes resueltos individualmente cuando exista una identidad externa confirmada.

No se inferirá una empresa por el dominio del correo, por el nombre de la reunión ni por sus participantes. Tampoco se asumirá que un proyecto pertenece a la única empresa asociada.

## 3. Contenido publicable

### 3.1 Matriz de selección

| Grupo | Contenido | Política inicial propuesta |
|---|---|---|
| Reunión | UUID local, título, inicio, fin y estado | Incluido en la publicación mínima; fechas normalizadas a RFC 3339 |
| Workspace | UUID local y vínculo al workspace remoto | Obligatorio para enrutar, no para crear otro workspace |
| Participantes | IDs locales, identidad externa confirmada y nombre visible | Opcional; no resolver por nombre |
| Destinos | IDs canónicos de empresas y proyectos | Selección explícita; cardinalidad múltiple |
| Transcripción | ID lógico, versión, estado de revisión, motores y locales solicitados | Publicar solo la versión seleccionada y revisada |
| Segmentos | UUID, secuencia, texto efectivo revisado, texto original opcional, timestamps y grabación fuente | Incluidos cuando se publica la transcripción |
| Correcciones | ID, segmento, texto original/corregido, base de confirmación y fecha | Incluidas como procedencia separada |
| Diarización | etiqueta temporal, intervalos y proveedor | Opcional; nunca equivale a identidad real |
| Identidades de hablante | asignaciones confirmadas por usuario | Opcional y separadas de diarización |
| Notas | notas seleccionadas por el usuario | Excluidas por defecto |
| Momentos importantes | timestamp y referencia local | Opcionales |
| Referencias de audio | ID, canal, duración, MIME, tamaño, SHA-256 y clave lógica | Metadatos por defecto; no el archivo |
| Audio original | bytes del archivo | Excluido; flujo y consentimiento independientes |
| Resumen | objeto estructurado con estado y evidencia | No disponible todavía; no publicar texto inventado |
| Acuerdos | objetos estructurados con evidencia y revisión | No disponibles todavía |
| Tareas | objetos estructurados con propietario, estado y evidencia | No disponibles todavía |

### 3.2 Datos derivados futuros

Resumen, acuerdos, decisiones, compromisos y tareas no deben incorporarse como un bloque genérico producido por un LLM. Antes de publicarlos, TwinVault necesitará entidades locales estructuradas con:

- ID estable;
- estado `observed`, `inferred` o `confirmed`;
- evidencia por segmento y rango temporal;
- versión del extractor/modelo;
- correcciones y revisión humana;
- reglas para invalidarlos cuando cambia la transcripción fuente.

Hasta entonces, la primera integración debe limitarse a reunión, destinos, participantes confirmados, transcripción revisada y metadatos de evidencia.

El modelo actual conserva instantes absolutos mediante `Date`, pero no la zona horaria original de la reunión como campo independiente. El contrato inicial debe transmitir fechas normalizadas; una zona original solo podrá publicarse cuando TwinVault la modele explícitamente, sin inferirla de la configuración actual del Mac.

## 4. Modelo del manifiesto

El contrato debe versionarse independientemente de la versión de la aplicación. Ejemplo conceptual abreviado:

```json
{
  "contractVersion": "1.0",
  "source": {
    "system": "twinvault",
    "installationId": "opaque-installation-id",
    "localWorkspaceId": "uuid",
    "localMeetingId": "uuid"
  },
  "publication": {
    "operationId": "uuid",
    "publicationRevision": 1,
    "authorizedAt": "RFC3339",
    "contentDigest": "sha256-of-canonical-manifest",
    "authorizationScope": ["meeting.metadata", "transcript.reviewed"]
  },
  "destination": {
    "workspaceId": "company-os-workspace-id",
    "canonicalMeetingId": null,
    "associations": [
      { "type": "company", "id": "company-os-company-id" },
      { "type": "project", "id": "company-os-project-id" }
    ]
  },
  "meeting": {
    "title": "Example",
    "startedAt": "RFC3339",
    "endedAt": "RFC3339"
  },
  "transcription": {
    "transcriptionId": "uuid",
    "versionId": "uuid",
    "version": 3,
    "reviewedAt": "RFC3339",
    "reviewAttestationDigest": "sha256",
    "segments": []
  },
  "audioEvidence": [
    {
      "recordingId": "uuid",
      "channel": "systemAudio",
      "sha256": "sha256",
      "mimeType": "audio/mp4",
      "byteSize": 123,
      "durationSeconds": 45.2,
      "binaryIncluded": false
    }
  ]
}
```

La clave lógica local del archivo puede formar parte del historial local, pero no debe exponerse como ruta absoluta. Company OS no necesita conocer la estructura del disco del usuario.

### 4.1 Instantánea, no referencia mutable

El contenido autorizado debe congelarse antes del primer envío. Un reintento reutiliza exactamente los mismos bytes canónicos y el mismo `contentDigest`. Si el usuario cambia una corrección, participantes, destinos o alcance, se crea una nueva revisión de publicación con una nueva autorización; nunca se modifica silenciosamente una operación ya confirmada.

## 5. Identidad y resolución

### 5.1 Usuario y workspace

- Company OS autentica al usuario y decide sus permisos efectivos.
- TwinVault guarda únicamente referencias opacas y tokens en Keychain.
- El vínculo `localWorkspaceID → companyOSWorkspaceID` requiere selección y confirmación del usuario.
- Un cambio de cuenta o workspace invalida la previsualización y exige autorizar de nuevo.

### 5.2 Personas

`ExternalIdentityLink` ya evita unir personas por nombre. Para Company OS, la resolución futura debe usar una clave externa confirmada, por ejemplo `(workspace, "company-os", personID)`. Una persona sin vínculo puede:

1. omitirse de la publicación;
2. vincularse manualmente a una persona canónica;
3. proponerse como nueva persona mediante un flujo separado y autorizado.

La opción nunca se elige automáticamente.

### 5.3 Empresas y proyectos

TwinVault no tiene actualmente entidades canónicas de empresa o proyecto. La primera versión debe consultar catálogos autorizados de Company OS y guardar solo referencias seleccionadas. No se crearán tablas de CRM, copias completas de clientes ni heurísticas de identidad dentro de Swift.

### 5.4 Reunión canónica

Company OS debe poder resolver de forma idempotente la clave externa:

```text
(sourceSystem, sourceInstallationID, sourceWorkspaceID, localMeetingID)
```

La respuesta devuelve siempre el mismo `canonicalMeetingID` para esa clave. Una vinculación manual a una reunión existente debe quedar auditada y protegida por permisos.

## 6. Contratos API propuestos

Las rutas son propuestas para revisión conjunta; no afirman que Company OS las implemente hoy.

### 6.1 Descubrimiento y permisos

```http
GET /v1/me/workspaces
GET /v1/workspaces/{workspaceId}/publication-capabilities
GET /v1/workspaces/{workspaceId}/companies?query=...
GET /v1/workspaces/{workspaceId}/projects?query=...
GET /v1/workspaces/{workspaceId}/people?externalSystem=twinvault&externalId=...
```

La respuesta de capacidades debe informar scopes efectivos, tipos permitidos, tamaño máximo, política de retención y si el audio está permitido. La UI no debe deducir permisos a partir de roles locales.

### 6.2 Crear o vincular reunión

```http
PUT /v1/workspaces/{workspaceId}/external-meetings/twinvault/{externalMeetingKey}
Authorization: Bearer <token>
Idempotency-Key: <persisted-operation-key>
Content-Type: application/json
```

Solicitud: metadatos mínimos, identidad de origen y, si procede, `linkToCanonicalMeetingId`.  
Respuesta: `canonicalMeetingId`, `externalLinkId`, revisión remota y estado `created` o `linked`.

La API debe rechazar con conflicto una misma clave externa vinculada a dos reuniones canónicas distintas.

### 6.3 Asociar empresas y proyectos

```http
PUT /v1/meetings/{canonicalMeetingId}/associations
If-Match: <remote-revision>
Idempotency-Key: <persisted-operation-key>
```

La solicitud contiene el conjunto explícito de asociaciones y su tipo. `PUT` expresa el snapshot autorizado; Company OS debe validar cada ID y permiso. Un conflicto de revisión obliga a refrescar y pedir confirmación, no a sobrescribir.

### 6.4 Publicar transcripción revisada

```http
PUT /v1/meetings/{canonicalMeetingId}/transcriptions/{transcriptionId}/versions/{version}
Idempotency-Key: <persisted-operation-key>
Content-Digest: sha-256=:...:
```

La solicitud contiene motores, revisión, segmentos, timestamps, grabación fuente, correcciones y digest de atestación. La respuesta debe devolver `remoteTranscriptionVersionId`, digest aceptado, revisión remota y enlaces a cualquier operación derivada.

La combinación `(canonicalMeetingId, sourceSystem, transcriptionId, version, reviewAttestationDigest)` debe ser única. Mismo identificador y mismo digest devuelve la confirmación anterior; mismo identificador con digest diferente devuelve conflicto.

### 6.5 Asociar documentos

```http
POST /v1/meetings/{canonicalMeetingId}/document-associations
Idempotency-Key: <persisted-operation-key>
```

Solo asocia IDs de documentos ya autorizados en Company OS. Subir adjuntos binarios sería otro contrato y otra selección; no se incluye en el primer incremento.

### 6.6 Consultar publicación

```http
GET /v1/publication-operations/{operationId}
```

Respuesta mínima:

```json
{
  "operationId": "uuid",
  "status": "accepted|processing|confirmed|failed|requires_action",
  "canonicalMeetingId": "id",
  "receiptId": "id",
  "acceptedDigest": "sha256",
  "error": null
}
```

### 6.7 Corregir o invalidar conocimiento derivado

Una nueva revisión no debe borrar la anterior. Company OS necesita un contrato de supersesión:

```http
POST /v1/publication-operations/{confirmedOperationId}/supersede
Idempotency-Key: <new-operation-key>
```

La solicitud referencia la nueva publicación y el motivo. Company OS debe marcar como potencialmente obsoleto el conocimiento derivado de segmentos modificados, conservar auditoría y decidir qué requiere recomputación o revisión humana.

## 7. Idempotencia e integridad

La protección contra duplicados usa cuatro capas:

1. **Identidad de origen:** instalación, workspace local y UUID de reunión.
2. **Identidad de artefacto:** `transcriptionID`, versión y digest de revisión.
3. **Identidad de operación:** UUID persistido antes del primer intento y reutilizado en todos sus reintentos.
4. **Digest de contenido:** SHA-256 de JSON canónico y, por separado, hashes de archivos originales.

Reglas:

- repetir una operación confirmada devuelve el mismo recibo;
- un timeout no autoriza a generar una clave nueva: primero se consulta el estado;
- una clave reutilizada con contenido diferente produce conflicto;
- una corrección posterior genera nueva revisión, nueva autorización y nueva operación;
- segmentos conservan UUID y timestamps de la evidencia local;
- tiempos de segmento son relativos a la grabación; `meetingTimelineOffset` se transmite por separado cuando existe;
- hashes de audio prueban qué archivo sustentó la transcripción, pero no demuestran identidad del hablante;
- etiquetas de diarización y personas confirmadas siguen siendo objetos distintos.

## 8. Historial local futuro

Para que un cierre de la app o un fallo de red no pierda trazabilidad, una fase futura necesitará persistir de forma aditiva:

### `PublicationRecord`

- `id` / `operationID`;
- reunión local y workspace local;
- usuario/cuenta y workspace remotos opacos;
- reunión canónica y destinos seleccionados;
- alcance de datos autorizado;
- IDs y versiones exactas publicadas;
- digest del manifiesto y clave de idempotencia;
- estado, número de intentos y próximo reintento;
- timestamps de autorización, envío y confirmación;
- recibo remoto;
- error estructurado saneado;
- referencia a la operación reemplazada o que la reemplaza.

### `ReviewAttestation`

- reunión, transcripción, versión y segmentos;
- conjunto de correcciones y digest del texto efectivo;
- usuario local que confirmó y fecha;
- Health Check utilizado y advertencias aceptadas.

Estos modelos no se implementan en este incremento. Cuando se implementen, usarán una migración SQLite aditiva y reversible; no alterarán audio, versiones o correcciones existentes.

## 9. Seguridad y privacidad

- OAuth 2.1 Authorization Code con PKCE o el mecanismo corporativo aprobado por Company OS.
- Tokens de acceso cortos; refresh token y referencias sensibles solo en macOS Keychain.
- TLS obligatorio y validación normal de plataforma; no criptografía casera.
- Scopes mínimos, por ejemplo `meetings:publish`, `transcripts:publish`, `targets:read`; audio separado.
- Company OS revalida autorización en cada operación y no confía en controles de la UI.
- La pantalla de consentimiento muestra workspace, empresas/proyectos, versión y categorías exactas.
- Ningún body de transcripción, token o nombre sensible en logs y telemetría.
- Los errores persistidos se sanean y no almacenan respuestas completas del servidor.
- Cerrar sesión elimina tokens de Keychain, pero no borra evidencia local ni el historial de publicación.
- Exportación, retención, revocación y borrado propagado necesitan políticas acordadas entre ambos productos.
- La publicación de audio exige un flujo separado, consentimiento explícito, política de tamaño/retención y configuración habilitada por Company OS.

Antes de producción deben documentarse finalidad, base jurídica, roles de responsable/encargado, residencia, retención y proceso de ejercicio de derechos. El diseño técnico no sustituye esa evaluación.

## 10. Errores y reintentos

| Clase | Ejemplos | Comportamiento TwinVault futuro |
|---|---|---|
| Validación local | Health Check con errores, versión no revisada | Bloquear antes de red |
| `400/422` | contrato o evidencia inválida | Fallo no reintentable; mostrar campo accionable |
| `401` | token caducado | renovar una vez o pedir autenticación |
| `403` | permiso insuficiente | no reintentar; volver a selección/autorización |
| `404` | destino eliminado | refrescar catálogos y pedir nueva selección |
| `409/412` | idempotencia o revisión en conflicto | consultar estado; nunca sobrescribir automáticamente |
| `413` | payload demasiado grande | no fragmentar silenciosamente; adaptar contrato con aprobación |
| `429` | límite temporal | respetar `Retry-After` |
| `5xx` / red | indisponibilidad o timeout | backoff exponencial con jitter y misma clave |

Los reintentos automáticos solo pueden repetir una instantánea ya autorizada. No pueden ampliar el alcance, cambiar destinos, incluir audio ni adoptar una nueva versión.

Si la respuesta se pierde después de que Company OS confirme, TwinVault consulta por `operationID` o clave de idempotencia antes de reenviar. Tras un número acotado de intentos, el estado pasa a `requires_action`.

## 11. Dependencias requeridas de Company OS

La implementación no puede empezar hasta que Company OS confirme:

1. URL base y versionado estable de API.
2. Proveedor de identidad, PKCE, scopes y ciclo de tokens.
3. Identificadores y permisos de workspace, empresa, proyecto, persona y reunión.
4. Semántica para crear/vincular reuniones externas y sus restricciones de unicidad.
5. Contrato de transcripciones versionadas y límites de payload.
6. Soporte de idempotencia, consulta de operación y recibos de auditoría.
7. Política para superseder versiones e invalidar conocimiento derivado.
8. Catálogos consultables de empresas, proyectos y personas.
9. Retención, borrado, exportación, residencia y auditoría.
10. Política separada para documentos y audio, si llegan a habilitarse.

Estas son capacidades solicitadas, no cambios autorizados en Company OS Core.

## 12. Plan incremental posterior a aprobación

### Fase I0 — Alinear contrato

- Revisar este documento con Company OS y seguridad.
- Resolver decisiones abiertas y publicar un OpenAPI acordado.
- Crear fixtures contractuales sin credenciales ni datos privados.

### Fase I1 — Dominio local sin red

- Añadir `ReviewAttestation`, selección de contenido y manifiesto canónico.
- Validar elegibilidad, digest e idempotencia con tests deterministas.
- Seguir sin cliente HTTP ni cambio de Company OS.

### Fase I2 — Autenticación y descubrimiento de solo lectura

- Integrar autenticación aprobada y Keychain.
- Consultar workspaces, capacidades, empresas y proyectos.
- No publicar todavía.

### Fase I3 — Historial y previsualización

- Migración local aditiva para historial de publicación.
- UI de destino, alcance, previsualización y consentimiento.
- Tests de privacidad, cancelación y recuperación tras reinicio.

### Fase I4 — Publicación mínima

- Crear/vincular reunión y publicar metadatos + transcripción revisada.
- Sin audio, resumen, acuerdos, tareas ni inferencias.
- Confirmación remota e historial idempotente.

### Fase I5 — Revisiones e invalidación

- Publicar nuevas instantáneas tras correcciones.
- Superseder publicaciones y activar revisión de derivados en Company OS.

### Fase I6 — Contenido adicional

- Documentos y, solo si se aprueba, audio mediante autorización independiente.
- Objetos estructurados de decisiones/tareas únicamente cuando exista el Memory model con procedencia.

## 13. Quality gates

Antes de activar la primera publicación real:

- cero publicación sin gesto y confirmación explícitos;
- cero secretos fuera de Keychain;
- reintentos repetidos producen una sola reunión y una sola versión remotas;
- conflicto de digest falla cerrado;
- reiniciar TwinVault no pierde operación ni recibo;
- corregir un segmento no altera una publicación histórica;
- datos no seleccionados no aparecen en el manifiesto;
- audio nunca se incluye en el flujo de transcripción;
- permisos revocados detienen el envío;
- cada segmento remoto puede rastrearse a reunión, versión, grabación y timestamp locales.

## 14. Decisiones abiertas

1. Identidad estable de la instalación sin crear un identificador invasivo del dispositivo.
2. Formato oficial de JSON canónico y `Content-Digest`.
3. Vigencia máxima aceptable del Health Check.
4. Si cualquier corrección invalida automáticamente la atestación de revisión.
5. Semántica de múltiples empresas/proyectos y visibilidad cruzada.
6. Política cuando un participante no puede resolverse en Company OS.
7. Tamaño máximo y paginación/streaming de transcripciones largas.
8. Tratamiento de retirada de consentimiento y borrado propagado.
9. Comportamiento del Knowledge Core ante una versión supersedida.
10. Requisitos específicos para publicación de documentos o audio.

Ninguna de estas decisiones debe resolverse mediante supuestos dentro de TwinVault. Deben acordarse antes de implementar la API.
