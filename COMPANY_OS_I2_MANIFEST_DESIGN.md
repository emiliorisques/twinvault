# TwinVault → Knowledge — I2: diseño del manifiesto de publicación

**Estado:** diseño para revisión; no implementado

**Fecha:** 2026-10-11

**Base local:** I1 cerrado en `75274c9`
**Contrato común:** pendiente de aprobación por Company OS/Knowledge

Este documento define exclusivamente el contrato candidato de I2. No añade
red, credenciales, sincronización, persistencia, endpoints, migraciones ni UI de
publicación. Tampoco presupone que Company OS implemente las rutas o recursos
descritos. I1 permanece sin cambios.

## 1. Resultado del diseño

La unidad publicable será un `KnowledgePublicationManifest` versionado. Es una
propuesta inmutable que reúne:

- los bytes canónicos exactos certificados por I1;
- sus identidades locales y SHA-256;
- estados independientes de integridad, revisión, identidad, salud técnica,
  aprobación corporativa y verificación factual;
- una selección explícita de contenido y destino;
- ACL y sensibilidad propuestas;
- relaciones propuestas, nunca entidades canónicas creadas por TwinVault;
- una clave de idempotencia y procedencia suficiente para crear un recibo y
  un lineage futuros.

El manifiesto no es Knowledge, una Assertion, una firma digital ni una orden
para escribir directamente en PostgreSQL. Será la entrada candidata de un
futuro contrato común de Knowledge que también deberá servir a Loop,
Communications Intelligence y Document Service.

```text
TranscriptReviewAttestation de I1
        │ bytes canónicos exactos + SHA-256
        ▼
Draft local del manifiesto
        ├── Health Check vinculado
        ├── selección de contenido
        ├── ACL/sensibilidad propuestas
        └── relaciones propuestas
                │
                ▼
aprobación corporativa autenticada (futura)
                │
                ▼
Knowledge Publication Gateway (no existe todavía)
        ├── valida contrato, actor, workspace y permisos
        ├── verifica bytes certificados y hashes
        ├── decide/retiene propuestas de relaciones
        ├── crea Source/SourceVersion/Evidence de forma atómica
        └── devuelve recibo e identidad canónica
```

## 2. Semánticas que no se pueden combinar

| Dimensión | Pregunta que responde | Autoridad | Estado candidato | Lo que no demuestra |
|---|---|---|---|---|
| Integridad del contenido | ¿Los bytes siguen siendo exactamente los certificados? | Cálculo local y repetición del servidor | `verified`, `mismatch`, `unavailable` | Quién revisó o si es verdad |
| Revisión local | ¿Alguien accionó la revisión sobre ese snapshot exacto? | `TranscriptReviewAttestation` de I1 | `attested`, `stale`, `absent` | Identidad autenticada, calidad o verdad |
| Identidad del revisor | ¿El revisor fue autenticado por una autoridad aceptada? | Futuro Identity Provider/Company OS | `absent`, `local_unverified`, `authenticated` | Integridad o aprobación corporativa |
| Health Check | ¿La evidencia técnica cumplía una política concreta en ese momento? | Auditor local versionado | `not_run`, `passed`, `passed_with_warnings`, `failed`, `stale` | Revisión humana o veracidad |
| Aprobación corporativa | ¿Un actor autorizado aprobó este alcance, destino y ACL? | Futuro gateway/Company OS | `not_requested`, `pending`, `approved`, `rejected`, `revoked` | Verificación factual |
| Verificación de assertions | ¿Una afirmación derivada fue verificada? | Flujo editorial de Knowledge separado | `not_applicable`, `not_evaluated`, `unverified`, `verified`, `rejected` | Calidad de toda la fuente |

Reglas obligatorias:

1. Un SHA-256 es una comprobación de integridad, no una firma digital.
2. `localReviewerID` de I1, si aparece, es una referencia local no autenticada.
3. Una revisión local no concede autoridad corporativa para publicar.
4. Aprobar una fuente no convierte sus afirmaciones en hechos verificados.
5. Un Health Check correcto no revisa el significado del texto.
6. Ningún estado se deriva automáticamente de otro.

## 3. Perfil versionado del manifiesto

El identificador del primer perfil candidato es:

```text
https://company-os.example/contracts/knowledge-publication-manifest/1-0
```

`example` deja claro que aún no es un URI operativo. Cuando Knowledge apruebe
la propiedad del contrato, el URI y su política de compatibilidad deberán
cambiar a un namespace oficial estable.

Los artefactos de diseño incluidos son:

- `Documentation/Contracts/knowledge-publication-manifest-v1.schema.json`;
- `Documentation/Contracts/Examples/knowledge-publication-manifest-v1.valid.json`;
- `Documentation/Contracts/Examples/knowledge-publication-manifest-v1.invalid-schema.json`;
- `Documentation/Contracts/Examples/knowledge-publication-manifest-v1.invalid-semantic.json`.

El JSON Schema valida estructura, tipos y campos cerrados. No puede comprobar
SHA-256, Base64 decodificado, reglas entre campos, permisos ni existencia de
entidades. Esas reglas forman el validador semántico del contrato futuro.

### 3.1 Bloques de primer nivel

| Bloque | Función |
|---|---|
| `schema` | Nombre y versión independiente de TwinVault |
| `manifest` | ID inmutable, creación, cliente e idempotencia |
| `origin` | Instalación opaca, workspace local y reunión local |
| `content` | Identidades de transcripción/grabación y bytes exactos de I1 |
| `review` | Atestación local e identidad del revisor, separadas |
| `health_check` | Resultado técnico vinculado al mismo snapshot |
| `approval` | Aprobación corporativa futura del manifiesto exacto |
| `provenance` | Cómo y de qué evidencia se obtuvo el contenido |
| `selection` | Categorías exactas autorizadas para salir del dispositivo |
| `relationships` | Relaciones propuestas con entidades canónicas |
| `privacy` | Sensibilidad, categorías de datos y ACL solicitada |
| `assertion_verification` | Estado factual explícito; inicialmente no aplicable |
| `supersession` | Corrección, reemplazo o revocación solicitada |
| `integrity` | Algoritmos y digest del propio manifiesto |

### 3.2 Contenido certificado sin reescritura

`content.certified_content.bytes_base64` contiene exactamente
`TranscriptReviewAttestation.canonicalContent` de I1, sin parsear ni
reserializar. El receptor futuro deberá:

1. decodificar Base64;
2. calcular SHA-256 sobre esos bytes;
3. comparar con `content.content_sha256`;
4. comprobar que coincide con el hash de la atestación;
5. interpretar el JSON solo después de verificarlo;
6. comprobar las identidades internas contra los campos redundantes del
   manifiesto.

Así se evita que ordenar claves, normalizar Unicode, cambiar números o convertir
fechas produzca un contenido distinto al revisado. La codificación Base64 no es
cifrado y no aporta confidencialidad.

El manifiesto no contiene rutas absolutas. El audio se representa solo mediante
ID, canal, digest y metadatos. `binary_included` debe ser `false` en este perfil.

### 3.3 Digest del manifiesto

El digest de I1 protege el contenido certificado. Un segundo digest protegerá
la propuesta completa —destino, selección, relaciones y ACL— antes de una
aprobación corporativa futura.

Para evitar circularidad, `integrity.manifest_sha256` se calcula sobre una copia
JSON Canonicalization Scheme (RFC 8785) del manifiesto en la que
`integrity.manifest_sha256` y `approval.approved_manifest_sha256` se sustituyen
por 64 ceros ASCII. Tras aprobar, ambos campos contienen ese mismo digest. Esta
regla es candidata y depende de la decisión común de Knowledge sobre
canonicalización. I1 no se recalcula ni se modifica.

`manifest.idempotency_key` es un UUID opaco persistido antes del primer intento.
No contiene datos personales ni secretos. Reglas futuras:

- misma clave + mismo digest de manifiesto → mismo resultado/recibo;
- misma clave + digest diferente → conflicto;
- nuevo contenido, destino, selección, ACL o relaciones → nuevo manifiesto,
  nueva aprobación y nueva clave;
- un timeout reutiliza la misma clave y consulta estado antes de reenviar.

## 4. Estados y elegibilidad

### 4.1 Matriz de revisión, Health Check y publicación

| Integridad | Revisión local | Identidad | Health Check | Aprobación | Resultado |
|---|---|---|---|---|---|
| `verified` | `attested` | `absent`/`local_unverified` | `passed` | `not_requested` | Draft local válido; no publicable |
| `verified` | `attested` | `authenticated` | `passed` | `approved` | Elegible para envío futuro, sujeto a revalidación del servidor |
| `verified` | `attested` | `absent`/`local_unverified` | `passed` | `approved` | Elegibilidad dependiente de política: solo si Knowledge acepta revisión local no autenticada y el aprobador corporativo autenticado asume ese alcance |
| `verified` | `attested` | `authenticated` | `passed_with_warnings` | `approved` | Elegible solo si la aprobación enumera y acepta los códigos de warning |
| `verified` | `attested` | cualquiera | `not_run` | cualquiera | No elegible |
| `verified` | `attested` | cualquiera | `failed`/`stale` | cualquiera | No elegible |
| `verified` | `stale`/`absent` | cualquiera | cualquiera | cualquiera | No elegible; exige nueva atestación |
| `mismatch`/`unavailable` | cualquiera | cualquiera | cualquiera | cualquiera | No elegible; fallo cerrado |
| `verified` | `attested` | `authenticated` | `passed` | `pending`/`rejected`/`revoked` | No enviar |

`authenticated` significa identidad validada por el proveedor aceptado por
Company OS, no un UUID local. La autenticación futura debe suceder después de
I2 de diseño y no se implementa aquí.

### 4.2 Estado de publicación futuro

El manifiesto no afirma que ya fue publicado. Un futuro `PublicationOperation`
separado tendrá estados como `draft`, `authorized`, `submitted`, `confirmed`,
`failed`, `superseded` y `revoked`. Un recibo remoto será la única confirmación
de publicación. No debe incrustarse un estado remoto mutable dentro de la
SourceVersion inmutable.

## 5. Health Check vinculado

El Health Check requerido por el perfil debe ser una instantánea persistente y
versionada, no el `EvidenceHealthReport` transitorio actual.

La vinculación mínima propuesta incluye:

- `health_check_id` estable;
- versión del auditor y de la política;
- `checked_at`;
- meeting ID;
- recording ID y SHA-256 inspeccionado;
- transcript ID, version ID, número y content revision;
- content SHA-256 y attestation ID;
- resultado agregado;
- códigos estables de findings, sin mensajes arbitrarios como autoridad;
- códigos de warnings aceptados explícitamente en la aprobación.

### 5.1 Cambios que invalidan el Health Check

| Cambio | Health Check | Atestación I1 | Aprobación/manifest |
|---|---|---|---|
| Bytes, SHA-256, tamaño o duración del audio | `stale` | `stale` si está en snapshot | invalidar |
| Recording ID/canal/timeline offset | `stale` | `stale` | invalidar |
| Texto, corrección, segment ID o timestamps | `stale` | `stale` | invalidar |
| Transcript ID, version ID/número o content revision | `stale` | no aplica a nueva versión | invalidar |
| Nueva atestación sobre el mismo snapshot | repetir vínculo o Health Check según política | nueva atestación válida | invalidar aprobación anterior |
| Reparación de metadatos que cambia el snapshot | repetir | repetir | invalidar |
| Cambio de título no incluido en el snapshot técnico | sigue válido | sigue válida | nuevo digest/aprobación si se publica el título |
| Cambio de destino, relaciones, selección o ACL | sigue válido | sigue válida | invalidar aprobación y clave |
| Nueva versión de política de Health Check | `stale_by_policy` cuando la política lo exija | sigue válida | bloquear hasta repetir |
| Cambio de app sin cambio de bytes/política | sigue válido | sigue válida | no invalida por sí solo |

I2 de implementación necesitará diseñar y aprobar la persistencia de esta
instantánea. Este documento no cambia el Health Check actual ni añade una nueva
condición a la aplicación.

## 6. Relaciones propuestas

`relationships.proposals` admite los tipos pedidos:

- `company`;
- `person`;
- `project`;
- `process`;
- `process_run`;
- `participation`;
- `sector`;
- `decision`;
- `outcome`.

Cada propuesta contiene un ID local estable, tipo de relación extensible,
estado de resolución, base y, solo si fue seleccionado de un catálogo
autorizado, el ID canónico de destino.

Estados:

- `selected_existing`: el usuario seleccionó una entidad canónica visible;
- `confirmed_external_identity`: existe un vínculo externo explícitamente
  confirmado;
- `unresolved_candidate`: solo hay una propuesta para revisión;
- `rejected`: el usuario rechazó la relación.

Bases permitidas en v1:

- `user_selected`;
- `confirmed_external_link`;
- `source_declared`;
- `model_suggested`.

`model_suggested` nunca permite resolver o crear automáticamente una entidad.
El gateway debe mantenerla como propuesta o rechazarla. Un nombre, dominio de
correo o similitud textual no son identidad. TwinVault tampoco crea Company,
Person, Project, Process, Decision u Outcome canónicos.

Las relaciones son independientes del contenido certificado de I1. Modificarlas
no altera la atestación, pero sí el manifiesto y su aprobación corporativa.

## 7. Privacidad, sensibilidad y ACL

### 7.1 Clasificación propuesta

| Sensibilidad | Uso | Publicación automática |
|---|---|---|
| `local_private` | User Twin o contenido que debe permanecer en el dispositivo | Prohibida |
| `internal` | Uso corporativo ordinario dentro del workspace | Nunca automática; exige aprobación |
| `confidential` | Información empresarial o personal limitada | Aprobación y ACL explícitas |
| `restricted` | Máxima limitación contractual/regulatoria | Bloqueada salvo política específica aprobada |

### 7.2 Matriz de ACL

| Destinatario propuesto | Lectura | Recompartir | Derivar Knowledge | Requisito |
|---|---|---|---|---|
| Workspace completo | Opcional | Denegado por defecto | Separado | Actor con `knowledge:publish` y política compatible |
| Grupos/roles | Opcional | Denegado por defecto | Separado | IDs canónicos y permisos revalidados |
| Usuarios concretos | Opcional | Denegado por defecto | Separado | IDs canónicos; evitar listas innecesarias |
| Entidad vinculada | No concede acceso por sí sola | No | No | Relation ≠ ACL |
| Agent Service/Twin projections | Solo mediante consumidor autorizado | No implícito | Sí, con lineage | Política explícita y revocación propagable |

El manifiesto expresa `requested_acl`, no permisos efectivos. El servidor
calcula y devuelve la ACL efectiva en el recibo. Una asociación con una empresa
o proyecto nunca otorga acceso automáticamente.

`privacy.data_categories` permite declarar categorías como
`meeting_metadata`, `transcript_text`, `personal_data`, `business_confidential`
y `speaker_labels`. No se deben incluir rutas locales, secretos, tokens, ni
contenido del User Twin. `privacy.user_twin_included` debe ser siempre `false`
en este perfil y el schema lo fija con `const`.

## 8. Corrección, supersesión y revocación

- Una corrección posterior hace `stale` la atestación I1 actual.
- Tras nueva revisión, se crea un nuevo manifiesto con otra clave.
- `supersession.supersedes_publication_id` enlaza el futuro recibo anterior,
  pero no lo borra.
- Revocar requiere una operación autorizada separada con motivo, actor y fecha;
  editar el manifiesto antiguo está prohibido.
- Knowledge debe localizar derivados mediante:

```text
publication_id
  → source_version_id
  → evidence_id
  → assertion_id
  → derived knowledge / embeddings / summaries / Twin projections
```

La invalidación no transforma automáticamente una Assertion en `rejected`.
Según política podrá quedar `stale`, `withdrawn` o `review_required`.

## 9. Compatibilidad exacta con I1

| Dato I2 | Fuente I1 | Transformación permitida |
|---|---|---|
| Meeting ID | `TranscriptReviewAttestation.meetingID` | UUID textual minúsculo |
| Recording ID | `sourceRecordingID` | UUID textual minúsculo |
| Transcript ID | `transcriptionID` | UUID textual minúsculo |
| Version ID | `transcriptionVersionID` | UUID textual minúsculo |
| Transcript version | `transcriptionVersion` | Ninguna |
| Content revision | `reviewContentRevision` | Ninguna |
| Canonicalization version | `canonicalizationVersion` | Ninguna |
| Content SHA-256 | `contentSHA256` | Minúsculas; mismos bytes |
| Attestation ID | `id` | UUID textual minúsculo |
| Certified at | `certifiedAt` | RFC 3339 UTC para transporte |
| Reviewer local | `localReviewerID` | Solo `local_unverified`; nunca `authenticated` |
| Certified bytes | `canonicalContent` | Base64 estándar sin reserialización |

I1 no aporta actualmente:

- identidad corporativa autenticada;
- Health Check persistente vinculado al digest;
- aprobación corporativa;
- instalación opaca estable;
- selección/ACL;
- relaciones remotas canónicas;
- manifiesto, operation ledger o recibo.

Estas ausencias son dependencias posteriores, no defectos que justifiquen
reabrir I1.

## 10. Validación del contrato

El futuro validador se divide en cuatro capas:

1. **Schema:** estructura JSON, tipos, campos obligatorios y ausencia de campos
   desconocidos.
2. **Criptográfica:** Base64 válido, SHA-256 de los bytes certificados y digest
   del manifiesto.
3. **Semántica:** identidades internas coincidentes, atestación vigente, Health
   Check vinculado, warnings aceptados y reglas de supersesión.
4. **Autorización remota:** actor, workspace, capacidad, targets, ACL, retención
   y estado de las entidades.

El ejemplo `invalid-schema` falla en la capa 1. El ejemplo
`invalid-semantic` es deliberadamente estructuralmente válido, pero debe fallar
en las capas 2/3 porque declara un digest que no corresponde a sus bytes,
mezcla otra revisión y pretende usar identidad local como autenticada.

## 11. Dependencias del contrato común de Knowledge

Company OS/Knowledge debe decidir antes de autorizar implementación:

1. Propietario y namespace oficial del contrato.
2. Si el gateway vive en Core, Knowledge u otro servicio.
3. Perfil oficial de autenticación para una app macOS pública y scopes.
4. Definición de `knowledge:publish` y autoridad de aprobación.
5. Canonicalización del manifiesto (RFC 8785 u otra) y formato de digest.
6. Límite de payload y estrategia aprobada para transcripciones largas.
7. Source lógica, SourceVersion inmutable y Evidence en el modelo común.
8. Taxonomía extensible de tipos de fuente y locators.
9. Semántica de ACL solicitada frente a ACL efectiva.
10. Catálogos y APIs de lectura para Company, Person, Project, Process,
    ProcessRun, Participation, Sector, Decision y Outcome.
11. Qué propuestas pueden almacenarse sin crear entidades.
12. Ledger de idempotencia, recibo, consulta, supersesión y revocación.
13. Eventos/lineage para invalidar derivados y confirmar consumidores.
14. Retención, borrado, residencia, auditoría y tratamiento de PII.
15. Política específica para audio; queda fuera del perfil inicial.

Ningún endpoint se considera existente hasta que estas decisiones se reflejen
en un contrato aprobado y verificable.

## 12. Decisiones pendientes antes de implementar I2

### Bloqueantes

1. URI/nombre definitivo y propietario del contrato común.
2. Autenticación corporativa y significado de identidad `authenticated`.
3. Formato canónico/digest del manifiesto y tamaño máximo.
4. Persistencia y política de vigencia del Health Check vinculado.
5. Capacidad de publicación, aprobación y ACL efectiva.
6. IDs/catálogos realmente disponibles; actualmente Project y otros tipos no
   tienen contrato operativo confirmado.
7. Recibo e idempotency ledger del servidor.
8. Semántica de supersesión, revocación e invalidación de derivados.

### No bloqueantes para prototipos contractuales posteriores

- título y etiquetas visibles de UI;
- orden de presentación de propuestas;
- formato de resumen de findings para usuarios;
- futuras categorías adicionales de sensibilidad.

## 13. Orden recomendado tras aprobación

1. Aprobar el contrato común con Knowledge, Seguridad y Privacidad.
2. Congelar schema v1 y fixtures sintéticos compartidos entre productores.
3. Definir y persistir localmente un Health Check vinculado, en un incremento
   independiente y aditivo.
4. Diseñar autenticación/descubrimiento de solo lectura.
5. Añadir constructor y validador local del manifiesto, todavía sin red.
6. Añadir previsualización y aprobación explícita.
7. Implementar gateway, ledger y recibos en Company OS bajo autorización
   separada.
8. Solo entonces conectar el cliente y probar idempotencia/revocación con datos
   sintéticos.

Hasta una autorización posterior, este documento y sus fixtures son el único
resultado de I2. No se inicia ninguna implementación.
