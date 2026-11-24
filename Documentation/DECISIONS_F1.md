# Bandeja de decisiones — F1 (MOCK)

**Fecha:** 24 nov 2026 · **Rama:** `claude/decisiones-f1` (desde `main` 554ab9e) · **Estado:** F1 con datos inventados.
Sin red, sin Core, sin puente real, sin WhatsApp, LinkedIn ni correo. La grabación y la transcripción no se han tocado.

Especificación: repositorio `company-os`, rama `claude/app-local-comunicaciones`,
`docs/company-os/app-local-comunicaciones-spec.md` (§3.2 contrato, §3.3 bis cambios de la v2, §7 fases).
Maqueta web de referencia: https://claude.ai/artifact/1MEzz78uy4xgNiJdTByybo

## Qué hay

| Archivo | Qué hace |
|---|---|
| `Sources/TwinVault/Decisions/DecisionItem.swift` | Contrato `decision-item/1`: tipos, huella SHA-256 canónica y bytes firmados |
| `Sources/TwinVault/Decisions/DecisionValidation.swift` | Comprobaciones de cada tarjeta que baja: forma, límites, «WhatsApp solo en el Mac», lotes prohibidos en envíos, huella y **firma Ed25519 real (CryptoKit)**. Comprobación en vivo del texto editado (enlaces por fase, 1.000 caracteres, tope del día, envíos parados) |
| `Sources/TwinVault/Decisions/DecisionServices.swift` | Fronteras: servidor de decisiones, recibos, estado del puente (**solo recuentos**), aprobación al puente, hilo en un clic, acciones externas |
| `Sources/TwinVault/Decisions/DecisionMocks.swift` | MOCK: servidor falso (firma de verdad con una clave generada al arrancar), puente falso que **no envía nada**, 9 tarjetas inventadas |
| `Sources/TwinVault/Decisions/DecisionInboxModel.swift` | Lógica: orden por urgencia, filtro por canal, edición en la tarjeta, «Ahora no» (aplazar o rechazar), **deshacer**, lotes de bajo riesgo, LinkedIn copiar → «Lo he enviado», modo foco |
| `Sources/TwinVault/Decisions/DecisionViews.swift` | Pestaña Decisiones en SwiftUI: lista, tarjeta, modo foco con atajos, barra de deshacer, estado del puente y ajustes |
| `Sources/TwinVault/TwinVaultApp.swift` | Dos pestañas (Decisiones, Reuniones) y el modo demo |
| `Documentation/Contracts/decision-item-v1.schema.json`, `decision-envelope-v1.schema.json` + `Examples/decision-item-v1.*.json` | Esquemas JSON (2020-12) de la tarjeta y del sobre firmado, y 4 ejemplos de tarjeta (3 válidos, 1 inválido) |
| `Tests/TwinVaultTests/DecisionInboxTests.swift` | 27 pruebas |

## Reglas que el código garantiza (y prueba)

- **Durante el margen para deshacer no sale nada** (ni a Core ni al puente). Si la app se cierra durante el margen,
  la decisión se descarta y la tarjeta vuelve a estar pendiente.
- **Deshacer** quita la última decisión en espera; las demás siguen su propio margen.
- **Un WhatsApp que el servidor deja aprobar desde la web se descarta**, aunque esté bien firmado.
- **Los envíos nunca van en lote**; el lote exige `attach`/`link` con la misma `batch_key`.
- **El texto de WhatsApp y LinkedIn no viaja a Core**: solo la huella. El de correo o ficha, solo si se editó.
- **LinkedIn** solo se registra cuando Emilio pulsa «Lo he enviado».
- **Sobre firmado:** Core firma los bytes exactos del JSON de la tarjeta y la app solo enseña lo que sale de esos
  bytes, así que la firma cubre todo lo que se lee (frase, recomendación, comprobaciones, ficha, dueño). Una tarjeta
  manipulada, con otra firma, de otro usuario, caducada o ilegible se descarta, y no afecta a las demás.
- **Un WhatsApp solo llega al puente después de que Core registre la decisión.** Si Core falla, no sale nada; si ya
  se decidió en otro sitio, tampoco. El resultado del puente (programado, bloqueado o error) se manda después a Core.
- **Una tarjeta en curso no se puede decidir dos veces**: desaparece de la bandeja antes de llamar a nadie.
- Se respetan las acciones que permite cada tarjeta (`allowed`) y la caducidad también durante la sesión.
- La huella canónica no es ambigua (NFC, longitud delante de cada campo, nulo distinto de vacío).

## Cómo verla

Modo demo (no abre el almacén de reuniones de Emilio ni ningún servicio de audio):

```bash
cd ~/dev/wt-twinvault-decisiones && swift build --disable-automatic-resolution && TWINVAULT_DECISIONS_DEMO=1 .build/debug/TwinVault
```

Sin `TWINVAULT_DECISIONS_DEMO=1`, la app abre como siempre, con la pestaña Decisiones (MOCK) delante de Reuniones.

Pruebas:

```bash
cd ~/dev/wt-twinvault-decisiones && swift test --disable-automatic-resolution --filter DecisionInboxTests
```

## Límites conocidos

- **Proyecto de Xcode sin actualizar:** los archivos nuevos los coge SwiftPM. Desde Xcode, hay que añadir la carpeta
  `Decisions` al target (o abrir `Package.swift` en vez del `.xcodeproj`).
- **Sin revisión visual en pantalla** por parte de Claude (el ejecutable de SwiftPM no tiene bundle y no hay permiso
  de grabación de pantalla). Lo tiene que mirar Emilio con el modo demo.
- Los atajos A/E/N/S/Z del modo foco solo funcionan sin modificadores y con el foco fuera del texto. Esc primero sale
  del texto y luego del modo foco. ⌥⌘Z deshace la última decisión en cualquier vista (⌘Z queda para el texto).
- Cerrar la ventana o la app durante el margen descarta lo que estaba en espera.
- La clave pública de Core se fija hoy con la del servidor falso. En F3 irá fija en la app.
- **No se ha añadido ninguna dependencia** (CryptoKit y SwiftUI son del sistema).

## Revisión independiente (Claude, 24 nov)

Primera ronda sobre 787e31e: **NO CONFORME**, con 3 P1, 7 P2 y 5 P3.
- P1: doble envío mientras se confirmaba; el puente recibía antes de que Core registrara; la firma no cubría lo que se
  enseñaba.
- Todos los P1 y P2 están arreglados, con pruebas nuevas.
- P3 arreglados: fechas con fracciones de segundo y error aislado por tarjeta; esquema y Swift alineados; deshacer en
  LinkedIn; lotes por grupo; foco de VoiceOver sin usar eliminado; cerrar la ventana.
- Queda de P3 «elegir motivos con teclado tras N» (con Tab en la configuración por defecto de macOS no se llega a los
  botones). Pendiente de mirar con Emilio delante.

Segunda ronda sobre ff33a44: **CONFORME**. Los P1 y P2 están cerrados.
- Del P2 nuevo y los P3, arreglados en el commit siguiente:
  - solo cuenta el cierre de la ventana propia, con aviso al descartar lo que estaba en espera;
  - Bloq Mayús ya no anula los atajos;
  - «Ahora no» se oculta si no hay motivos permitidos;
  - `link_from`/`link_to` no pueden estar vacíos;
  - la confirmación manual de LinkedIn se registra aunque haya caducado;
  - si el puente no responde, se dice «no se sabe si lo aceptó»;
  - se avisa si no se puede pasar el resultado a Core.
- Quedan para F3 (con Core real):
  - reintentar los resultados del puente que no lleguen a Core;
  - reconciliar «aprobado en Core pero no entregado al puente» (entrega idempotente por `item_id` al abrir);
  - rechazar claves desconocidas al abrir el sobre;
  - un ejemplo de sobre firmado;
  - elegir los motivos con el teclado tras pulsar N.
