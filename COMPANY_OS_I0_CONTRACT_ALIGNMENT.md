# TwinVault ↔ Company OS — I0: contratos y dependencias

**Fecha de inspección:** 2026-10-11  
**Estado:** diseño para aprobación; sin implementación  
**Alcance inspeccionado:** Company OS Core, Agent Service, Communications
Intelligence, Microsoft Loop Importer, propuesta de Document Service y modelo
local de TwinVault.

Este incremento no modifica Swift, SQLite, PostgreSQL, Core, Agent Service ni
ningún servicio externo. Tampoco declara que los contratos propuestos existan.

## 1. Conclusión ejecutiva

Company OS no dispone hoy de una API general para publicar conocimiento desde
fuentes externas. Core puede autenticar usuarios, enumerar sus workspaces y
empresas visibles, leer Knowledge y asociar Sources o Assertions ya existentes
a una empresa. No puede crear Sources, Evidence o Assertions. Agent Service sí
los escribe, pero su escritor está acoplado a una tarea de investigación, un
lease y una aprobación de propuesta de agente; no es un puerto de ingesta
general.

Por tanto:

1. TwinVault no debe fingir una tarea de Agent Service ni escribir directamente
   en PostgreSQL.
2. Communications y Loop tampoco deben crear catálogos Knowledge paralelos.
3. Company OS debe definir un **contrato común de publicación revisada** en el
   límite de Knowledge.
4. El contrato debe aceptar versiones inmutables de una fuente, evidencia
   localizable, audiencia explícita, atestación de revisión y relaciones con
   entidades, manteniendo Assertions y conocimiento derivado como fases
   separadas.
5. TwinVault puede preparar I1 localmente cuando se apruebe, pero I2–I6 están
   bloqueados por decisiones de identidad nativa, proyectos, esquema Knowledge,
   autoridad de publicación y revocación.

## 2. Evidencia inspeccionada y clasificación

### 2.1 APIs reales de Company OS Core

Rutas operativas relevantes:

| Ruta | Estado | Capacidad real |
|---|---|---|
| `GET /api/v1/me` | Existe | Usuario, membresías, workspaces y permisos. Requiere identidad humana de la sesión web. |
| `GET /api/v1/companies` | Existe | Empresas visibles en el workspace de `X-Workspace-ID`; paginación, búsqueda y filtro por rol. |
| `GET /api/v1/companies/{id}` | Existe | Detalle de empresa si el actor puede leerla. |
| `GET /api/v1/companies/{id}/knowledge` | Existe | Lectura de Sources o Assertions ya vinculados. |
| `GET /api/v1/companies/{id}/context` | Existe | Proyección limitada; `documents` está siempre vacío. |
| `GET /api/v1/sources/{id}` | Existe | Lectura de Source y Evidence según ACL. |
| `GET /api/v1/evidence/{id}` | Existe | Lectura de evidencia; hereda permiso de su Source. |
| `GET /api/v1/assertions/{id}` | Existe | Lectura si la Assertion y toda su evidencia son legibles. |
| `PUT/DELETE /api/v1/companies/{id}/sources/{sourceId}` | Existe | Vincula o desvincula una Source existente; no crea ni revoca la Source. |
| `PUT/DELETE /api/v1/companies/{id}/assertions/{assertionId}` | Existe | Vincula o desvincula una Assertion existente; no la crea ni invalida. |
| Endpoints de proyectos | No existen | No hay modelo ni catálogo operativo de Project. |
| Endpoints de reuniones/transcripciones | No existen | No existe recurso canónico específico de meeting. |
| Ingesta de Source/Evidence/Assertion | No existe | Core es lector de Knowledge y no tiene privilegios de escritura sobre esas tablas. |
| Estado/supersesión/revocación de publicación | No existe | No hay operación ni recibo canónico. |

La idempotencia actual de Core se limita a operaciones concretas, como crear
una empresa o administrar grants. No es un ledger general de publicación.
El límite de contexto de 65.536 bytes tampoco permite reutilizar el endpoint de
contexto para transcripciones largas.

### 2.2 Knowledge real en Agent Service

El esquema existente aporta una base valiosa:

- `sources`: identidad, workspace, clave de origen, `content_hash`, referencias
  a artefacto original y extraído, clase, título, captura y metadata;
- `evidence`: Source, cita y locator;
- `assertions`: texto, tipo epistemológico, estado de verificación y hash de
  propuesta;
- `assertion_evidence`: trazabilidad Assertion → Evidence;
- `assertion_relations`: `replaces` y `derived_from`.

Limitaciones incompatibles con la ingesta común:

- `sources.kind` acepta solo `web`, `news` y `document`;
- no hay identidad lógica y número de versión explícitos;
- una Assertion exige `task_id` de Agent Service;
- el escritor exige task/lease y aprobación del hash exacto;
- faltan publicador, atestación, audiencia efectiva, estado de Source,
  supersesión y revocación;
- Core serializa la procedencia de Assertions como `agent_runtime` y reconoce
  que es incompleta;
- la aprobación editorial crea Assertions `UNVERIFIED`; no equivale a confirmar
  que una afirmación sea cierta.

El escritor actual debe seguir sirviendo a Agent Service. La ingesta compartida
no debe reutilizarlo fingiendo tareas, ni romper su compatibilidad.

### 2.3 Communications Intelligence

Existe un contrato local y un puerto, no un publicador operativo. Ya establece
principios que deben generalizarse:

- propuesta con workspace, versión de mensaje, evidencia, locator, claim y
  audiencia;
- decisión sobre el hash exacto por un revisor;
- idempotencia al publicar;
- revocación de origen e invalidación de derivados;
- leer un correo no concede autoridad para publicarlo corporativamente;
- aprobación no convierte una Assertion en `VERIFIED`.

No realiza escrituras operativas y su Microsoft Graph actual es simulado.

### 2.4 Microsoft Loop Importer

Es un exportador local aislado. Su manifiesto ya incluye `schema_version`,
source, identidad de origen, workspace, estado, SHA-256, hash de Markdown,
ruta relativa, enlaces, procedencia y bloques. Sin embargo:

- conserva solo la última versión;
- no detecta eliminaciones de forma completa;
- no tiene historial, atestación, ACL canónica, supersesión o revocación;
- no publica en Company OS;
- los documentos enlazados son referencias, no descargas.

Su manifiesto es un buen adaptador de origen, pero no debe transformarse en el
contrato canónico para todas las fuentes.

### 2.5 Document Service

No existe una implementación operativa. Core devuelve `documents: []`. El SQL
de diseño propone `documents`, versiones con SHA-256/MIME/tamaño/storage key y
relaciones con empresas, pero no forma parte de las migraciones reales. No se
puede tratar como dependencia disponible.

### 2.6 TwinVault local

TwinVault ya dispone de:

- UUID estable de Meeting, AudioRecordingReference, TranscriptionVersion y
  TranscriptSegment;
- `transcriptionID` estable y versión incremental;
- timestamps relativos a la grabación, recording ID y offset a timeline;
- proveedor/modelo/parámetros y locale cuando está disponible;
- metadatos de audio: SHA-256, MIME, bytes, duración y fecha de finalización;
- correcciones separadas que conservan texto original, corregido y fecha;
- etiquetas temporales de diarización separadas de personas confirmadas;
- Health Check y reparaciones locales auditables.

La carencia relevante es que `status = reviewed` y `reviewedAt` no certifican
el contenido exacto revisado. Una corrección posterior puede cambiar el texto
efectivo sin invalidar ese estado. Tampoco existe todavía una identidad de
publicador remoto, snapshot de ACL ni historial de publicación.

## 3. Matriz de contratos existentes y pendientes

Leyenda: **Sí** = operativo; **Parcial** = base reutilizable con carencias;
**Diseño** = contrato/documento sin implementación; **No** = ausente.

| Capacidad | Core | Agent/Knowledge | Communications | Loop | TwinVault | Necesidad común |
|---|---|---|---|---|---|---|
| Usuario/workspace | Sí, sesión web | Token de servicio por workspace | Scope local | Workspace de origen | Workspace local | Autenticación nativa y actor canónico |
| Empresas autorizadas | Sí, lectura | No | Candidatos, no canon | No | Solo vínculos externos locales | Reutilizar Core |
| Proyectos autorizados | No | No | No | No | Solo referencia futura | Nuevo modelo/API de Core |
| Identidad de origen | Parcial en Source | `origin_key` | message ID/version | source ID/URL | Meeting/transcription IDs | Namespace + ID lógico estable |
| Versión de fuente | No explícita | Hash como versión implícita | Sí | Última solamente | Sí | Source lógica + SourceVersion inmutable |
| SHA-256 | Sí al leer | Sí | Hash de propuesta | Sí | Sí audio; falta digest revisado | Algoritmo y bytes canónicos definidos |
| Procedencia | Parcial | Parcial y agent-specific | Diseño | Parcial | Fuerte local | Modelo multimodal común |
| Publicador | Actor Core para sus operaciones | Agente/task | Revisor propuesto | Proceso local | Usuario local | Actor autenticado + autoridad delegada |
| ACL/audiencia | Grants Core | No en Source | Audiencia explícita | Permisos de origen no capturados | No remota | Snapshot + política efectiva separada |
| Revisión exacta | No | Hash de propuesta | Diseño correcto | No | Estado, no atestación | ReviewAttestation inmutable |
| Evidence localizable | Sí al leer | Sí | Sí | Bloques | Sí segmentos | Locator tipado/extensible |
| Assertions | Sí al leer | Sí, task-bound | Propuesta | No | No en esta fase | Publicación separada, siempre epistemológica |
| Relaciones con entidades | Empresa–Source/Assertion | No | Propuestas | Jerarquía Loop | Links locales | EntityLink separado y multi-entidad |
| Idempotencia de publicación | No | Dedupe técnico | Diseño | Dedupe local | No | Ledger + request hash + receipt |
| Supersesión | No | Solo entre Assertions | Diseño | No | Versiones locales | Entre SourceVersions/publicaciones |
| Revocación | Grants, no Source | No | Puerto diseñado | No | No remoto | Estado, evento y propagación |
| Invalidar derivados | No | Relación, no propagación | Puerto diseñado | No | No remoto | Lineage ledger + consumidores |
| Recibo/estado | No | No | Diseño | Reporte local | No | Operación consultable |

## 4. Contrato común de publicación propuesto

### 4.1 Límite arquitectónico

La capacidad futura puede llamarse **Knowledge Publication Gateway** como
concepto, sin decidir todavía si vive en Core, en un servicio Knowledge o bajo
otro despliegue. Debe ser propiedad de Company OS y servir a Loop,
Communications, Document Service, TwinVault y futuros conectores.

```text
adaptador de origen
  └── propuesta local + revisión exacta
          │
          ▼
Knowledge Publication Gateway (autenticación, autoridad, ACL, idempotencia)
          │
          ├── Source lógica
          ├── SourceVersion inmutable + artefacto/metadatos
          ├── Evidence + locator
          ├── EntityLinks
          └── receipt + lineage/supersession/revocation

fase posterior e independiente:
Evidence → propuesta de Assertion → revisión → Assertion → derivados
```

### 4.2 Separación obligatoria

| Objeto | Responsabilidad | No debe confundirse con |
|---|---|---|
| `Source` | Identidad lógica del origen | Una versión o sus bytes |
| `SourceVersion` | Snapshot inmutable y con hash | Documento mutable o conocimiento derivado |
| `OriginalArtifact` | Bytes o referencia segura al original | Permiso para copiar o publicar esos bytes |
| `Metadata` | Propiedades descriptivas versionadas | Contenido original |
| `EntityLink` | Relación revisada con empresa/proyecto/etc. | Duplicado de la entidad canónica |
| `Evidence` | Fragmento localizable en una versión | Claim o Fact |
| `ReviewAttestation` | Quién revisó qué digest y bajo qué política | Verificación de verdad |
| `Assertion` | Claim con tipo epistemológico y evidencia | Resumen genérico o fuente |
| `DerivedKnowledge` | Resultado que declara todas sus dependencias | Evidencia original |
| `PublicationOperation` | Intención, idempotencia, estado y recibo | Source o SourceVersion |

### 4.3 Envelope conceptual

No es un endpoint existente ni un JSON Schema definitivo:

```json
{
  "contract_version": "knowledge-publication/1",
  "operation": {
    "operation_id": "uuid",
    "idempotency_key": "opaque",
    "request_digest": "sha256:...",
    "created_at": "RFC3339"
  },
  "publisher": {
    "actor_id": "company-os-user-or-service-id",
    "actor_type": "user|service",
    "workspace_id": "company-os-workspace-id",
    "client": "twinvault|communications|loop|document-service"
  },
  "source": {
    "namespace": "twinvault",
    "origin_id": "stable-logical-id",
    "source_type": "meeting.transcript",
    "title": "..."
  },
  "source_version": {
    "version_id": "origin-stable-version-id",
    "version": "origin-version-token",
    "content_digest": "sha256:...",
    "captured_at": "RFC3339",
    "supersedes_version_id": null,
    "metadata": {},
    "original_artifact": {
      "included": false,
      "mime_type": "application/json",
      "byte_size": 0,
      "digest": "sha256:...",
      "reference": null
    }
  },
  "provenance": {
    "origin_system": "twinvault",
    "origin_account_or_installation": "opaque-stable-id",
    "extraction_method": "local-reviewed-transcript",
    "extractor_version": "...",
    "parent_refs": []
  },
  "review": {
    "status": "reviewed",
    "attestation_id": "uuid",
    "reviewed_digest": "sha256:...",
    "reviewer_id": "company-os-user-id",
    "reviewed_at": "RFC3339",
    "policy_version": "..."
  },
  "acl": {
    "publication_audience": [],
    "origin_acl_snapshot_or_epoch": null,
    "retention_policy": null
  },
  "entity_links": [
    {"entity_type": "company", "entity_id": "uuid", "relation": "about"}
  ],
  "evidence": [
    {
      "evidence_id": "origin-stable-id",
      "quote": "...",
      "locator": {
        "type": "media-time-range",
        "source_recording_id": "uuid",
        "start_seconds": 12.3,
        "end_seconds": 17.8
      }
    }
  ]
}
```

Los campos `source_type`, `locator.type` y relaciones deben ser strings
extensibles y versionados, no checks cerrados que obliguen a disfrazar correo o
transcripción como `document`. El contrato de transporte no decide por sí solo
el esquema PostgreSQL.

### 4.4 Identidad e idempotencia

La identidad lógica mínima es:

```text
(workspace_id, source.namespace, source.origin_id)
```

Una versión se identifica independientemente mediante `version_id`, token de
versión del origen y digest. Las reglas propuestas son:

- misma clave idempotente + mismo request digest → mismo recibo;
- misma clave + digest diferente → `409 idempotency_conflict`;
- mismo origin/version + mismos bytes → reconciliación, no duplicado;
- mismo origin/version + bytes diferentes → conflicto de integridad;
- una corrección crea nueva SourceVersion; nunca sobrescribe la anterior;
- `supersedes` no borra historial ni implica automáticamente revocación;
- un timeout se reconcilia por operation ID o clave antes de reintentar.

El receipt debe devolver como mínimo operation/publication ID, Source ID,
SourceVersion ID, Evidence IDs aceptados, estado, digest recibido y fecha. Los
IDs canónicos nunca se inventan en el cliente.

### 4.5 Review y verificación

La atestación certifica que una persona autorizó un digest exacto, un alcance y
una audiencia. No certifica que todos los claims sean verdaderos. Por ello:

- una SourceVersion puede estar `reviewed`;
- una Assertion derivada sigue `UNVERIFIED` salvo un proceso distinto;
- cualquier cambio de contenido, Evidence, redacción, audiencia o destinos
  invalida la atestación anterior;
- el servidor vuelve a validar actor, workspace, autoridad, targets y ACL;
- un permiso de lectura sobre el origen no concede `knowledge:publish`.

## 5. Empresas y proyectos autorizados

### Empresas

Core ya ofrece el camino de lectura correcto:

1. `GET /api/v1/me` para membresías y permisos;
2. elección explícita de workspace;
3. `GET /api/v1/companies?q=...` con `X-Workspace-ID`;
4. conservar el ID canónico seleccionado, no copiar el CRM ni resolver por
   nombre;
5. revalidar acceso al publicar.

Esto no está utilizable todavía desde TwinVault porque Core implementa una
sesión web/BFF y credenciales opacas de servicio, no un flujo aprobado para una
app macOS nativa. La autenticación nativa es una decisión de Core/Seguridad.

### Proyectos

No existe un recurso Project. Antes de I2, Company OS debe decidir:

- identidad, workspace y ACL de Project;
- relación opcional y de cardinalidad múltiple con empresas;
- endpoint de búsqueda/listado accesible;
- enlace genérico Project–SourceVersion o Project–Source;
- comportamiento cuando un proyecto cambia de permisos o se archiva.

TwinVault no creará una tabla CRM local para suplir esta ausencia. Hasta que
Project exista, la selección de empresa puede funcionar conceptualmente y la de
proyecto debe declararse bloqueada, no simularse con texto libre.

## 6. Corrección, supersesión, revocación e invalidación

### 6.1 Corrección

Una transcripción corregida genera una nueva SourceVersion que declara
`supersedes_version_id`. La anterior permanece auditable. Evidence nueva
apunta exclusivamente a la nueva versión, aunque conserve IDs de origen para
comparación.

### 6.2 Revocación

Revocar es un evento autorizado y con motivo, actor y fecha. No equivale a
desvincular una Source de una empresa. Debe:

1. impedir nuevas lecturas según la política aplicable;
2. conservar un tombstone y el receipt de revocación;
3. localizar todos los derivados por lineage;
4. emitir invalidación transaccional mediante outbox/evento durable;
5. recibir confirmación de consumidores: contextos, caches, embeddings,
   resúmenes, Twins y Agent Service;
6. marcar derivados como `stale`, `withdrawn` o `review_required` según una
   taxonomía acordada, sin inventar que son `REJECTED`.

### 6.3 Lineage mínimo

Cada conocimiento derivado debe declarar dependencias exactas:

```text
derived_resource_id
  → assertion_id (si existe)
  → evidence_id
  → source_version_id
  → publication_id
```

La comprobación de Core que exige leer todas las Sources citadas protege parte
de la lectura de Assertions, pero no sustituye el ledger de revocación: no
invalida caches, embeddings, resúmenes o Twin projections, y no expresa una
revocación global de SourceVersion.

## 7. Incremento I1 preciso: certificación local, sin red

I1 debe limitarse a TwinVault y seguir offline. Requiere una aprobación
posterior antes de implementarse.

### 7.1 Objetivo

Certificar exactamente qué versión de transcripción, texto efectivo,
correcciones, segmentos y evidencia técnica revisó el usuario, sin publicar ni
guardar credenciales.

### 7.2 Modelo local aditivo propuesto

`TranscriptReviewAttestation`:

- UUID estable;
- meeting ID, transcription ID, version ID y número;
- source recording ID y SHA-256 del audio inspeccionado;
- lista ordenada de segmentos: ID, secuencia, timestamps y digest del texto
  original;
- lista ordenada de correcciones: ID, segment ID, original/corrected digest y
  fecha;
- digest del texto efectivo y digest canónico del snapshot completo;
- identidad local opaca del revisor y fecha;
- versión de esquema/canonicalización;
- resultado de Health Check: fecha, códigos estables, errores y warnings
  aceptados; nunca IDs aleatorios de UI;
- estado calculado `valid` o `stale`, no mutable manualmente.

No debe contener workspace remoto, empresa, proyecto, tokens ni estado de
publicación.

### 7.3 Canonicalización

- UTF-8, claves y arrays con orden definido, fechas RFC 3339 UTC y números con
  representación normativa;
- IDs y secuencia evitan depender del orden accidental de persistencia;
- los digests se calculan con CryptoKit/SHA-256;
- el snapshot incluye contenido, locators, correcciones y audio hash;
- el perfil ASR se conserva como procedencia, pero cambiar un nombre visible no
  invalida el contenido salvo que forme parte del alcance revisado;
- no se diseña criptografía ni firma propia. Una firma corporativa futura, si se
  requiere, será un contrato de Company OS/Keychain separado.

### 7.4 Reglas

- solo una TranscriptionVersion `completed` puede atestiguarse;
- atestiguar no modifica segmentos originales;
- el estado `reviewed` pasa a ser una proyección compatible del attestation
  válido, no la única prueba;
- cualquier cambio en el snapshot produce `stale` y exige nueva revisión;
- re-transcribir conserva atestaciones históricas, pero ninguna aplica a la
  nueva versión;
- reparar metadatos solo conserva validez si el SHA-256 del audio y el snapshot
  revisado no cambian;
- una atestación no vincula hablantes temporales con personas por inferencia.

### 7.5 Persistencia y compatibilidad

- migración aditiva, sin reescribir Meetings o audios;
- lectura de datos antiguos sin atestación sigue funcionando y los muestra como
  `review required` para futura publicación;
- eliminación local futura debe tratar la atestación como metadato dependiente,
  no como copia del audio;
- ninguna operación de I1 accede a red.

### 7.6 Tests de aceptación de I1

1. El mismo snapshot produce el mismo digest.
2. Orden incidental distinto produce el mismo digest canónico.
3. Cambiar texto, timestamps, recording ID/hash, corrección o segment ID marca
   la atestación como obsoleta.
4. Una nueva versión no hereda revisión.
5. Health Check con error bloquea atestación; warning exige aceptación explícita.
6. Persistir/cerrar/reabrir recupera IDs y digest exactamente.
7. Repositorio antiguo decodifica sin migración destructiva.
8. Corregir un segmento conserva original y atestación histórica.
9. Diarización temporal y persona confirmada siguen separadas.
10. Ninguna prueba necesita audio privado ni red.

### 7.7 Fuera de I1

Cliente HTTP, OAuth/PKCE, Keychain, catálogos remotos, selección de targets,
publication manifest definitivo, outbox, reintentos, recibos y revocación
remota. Eso pertenece a I2 o posterior tras decisiones de Company OS.

## 8. Dependencias y decisiones de Company OS

Antes de I2:

1. **Autenticación nativa:** OAuth/OIDC para app pública macOS, PKCE o flujo
   alternativo, scopes, refresh, logout y revocación. La cookie BFF actual no se
   asumirá reutilizable.
2. **Projects:** modelo, ACL, API de lectura y enlaces.
3. **Autoridad:** capacidad distinta `knowledge:publish`; leer origen o editar
   empresa no basta.
4. **Propietario del gateway:** Core vs Knowledge service, despliegue y contrato
   OpenAPI.

Antes de I3:

5. JSON canónico/digest, IDs, límites, chunking y manejo de transcripciones
   largas.
6. Semántica de audience/ACL y si una publicación es snapshot corporativo o
   permanece ligada a permisos del origen.
7. Taxonomía extensible de Source y locators.
8. Política de retención, borrado, residencia, auditoría y PII.

Antes de I4:

9. Esquema Knowledge para Source lógica/Version sin romper Agent Service.
10. Endpoint común, idempotency ledger, receipt y consulta de estado.
11. Transaction boundary para SourceVersion, Evidence, ACL y EntityLinks.
12. Servicio/document storage: inline vs object reference y verificación de
    digest. Audio queda excluido por defecto.

Antes de I5:

13. Supersession/revocation state machine.
14. Lineage registry, outbox, consumidores y garantía de invalidación.
15. Tratamiento de assertions afectadas sin confundir obsolescencia con falsedad.
16. Reconciliación y recuperación ante fallos parciales.

Antes de I6:

17. Contratos estructurados para summary/decision/task/commitment con Evidence y
    estados `observed`, `inferred` o `confirmed`.
18. Consentimiento y flujo separado para binarios/audio.

## 9. Riesgos y decisiones abiertas

| Riesgo | Impacto | Decisión/mitigación |
|---|---|---|
| Reutilizar Agent task writer | Procedencia falsa y acoplamiento | Crear puerto común; no tareas ficticias |
| Manifiesto distinto por conector | Duplicidad de Knowledge | Envelope común + extensiones namespaced |
| `kind` cerrado | Datos disfrazados como document | Taxonomía extensible acordada |
| Revisión sin digest exacto | Se publica contenido no revisado | I1 antes de red |
| Auth web en app nativa | Tokens/cookies inseguros | Decisión Core/Seguridad antes de I2 |
| Proyecto inexistente | Destino ambiguo | No simular; implementar contrato canónico |
| Grant de lectura usado para publicar | Exfiltración | Capacidad de publicación independiente |
| Source revocada pero derivados vivos | Twins/caches incorrectos | Lineage + outbox + ACK de consumidores |
| Desvincular empresa se interpreta como revocar | Pérdida o falsa seguridad | Estados y operaciones separados |
| Aprobado se interpreta como VERIFIED | Hechos falsamente confirmados | Separar review de verification |
| Transcript grande supera Core | Fallos o truncado silencioso | Protocolo de upload/chunking aprobado |
| Hash sin canonicalización | Conflictos entre plataformas | Especificación y fixtures contractuales |
| Audio se publica por referencia | Privacidad y enlaces inútiles | Solo metadatos; binario en flujo separado |
| Cambiar Knowledge rompe Agent | Regresión operativa | Migración compatible + contract tests |

Decisiones abiertas principales:

- ¿Source representa identidad lógica o una versión? Se recomienda separar
  ambos conceptos, preservando una vista compatible para Core.
- ¿Quién es dueño del gateway y del ledger?
- ¿La ACL publicada es snapshot corporativo independiente o se revoca cuando
  cambia el origen? Debe ser explícito por publicación.
- ¿Qué parte del original se copia y dónde se almacena?
- ¿Qué identidad local estable y respetuosa con privacidad usa TwinVault para
  su namespace de origen?
- ¿La supersesión invalida derivados inmediatamente o los marca para revisión?
- ¿Qué SLA garantiza que todos los lectores hayan aplicado una revocación?

## 10. Orden recomendado

1. **I0 — este documento:** aprobar propietario, semántica y decisiones.
2. **Company OS C0:** especificar contrato común y fixtures, sin servicio real.
3. **I1 TwinVault:** ReviewAttestation local determinista y tests offline.
4. **Company OS C1:** diseñar compatibilidad del esquema Knowledge, publisher
   authority, Projects, revocación y auth nativa.
5. **I2 TwinVault:** autenticación y descubrimiento de solo lectura, sin publicar.
6. **Company OS C2:** gateway en entorno aislado con contract tests de Loop,
   Communications, Document y TwinVault.
7. **I3 TwinVault:** preview, consentimiento e historial/outbox local usando fake.
8. **I4:** publicación mínima de metadata + transcripción revisada, sin audio ni
   Assertions automáticas.
9. **I5:** supersesión, revocación e invalidación end-to-end.
10. **I6:** contenido derivado estructurado y binarios solo con aprobación
    separada.

## 11. Criterios de aprobación para salir de I0

- Company OS reconoce qué APIs existen y cuáles son propuestas.
- Knowledge/Core designa propietario del contrato común.
- Loop, Communications, Document y TwinVault aceptan el mismo envelope base.
- Review no equivale a verification.
- SourceVersion, Evidence, Assertion y DerivedKnowledge permanecen separados.
- Se acuerda que no habrá SQL directo ni tareas Agent ficticias.
- Se decide el camino para auth nativa, Projects, publication authority y
  revocación antes de I2.
- Se aprueba o corrige el alcance exacto de I1 antes de tocar código.

Hasta esa aprobación, TwinVault permanece local-first y no se implementa ninguna
sincronización.
