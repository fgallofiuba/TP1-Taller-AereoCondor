---
title: TP1 — Taller de Programación - Cátedra Camejo

---

TP — Reserva concurrente de asientos en una aerolínea

Introducción

Cóndor del Sur es una aerolínea regional que opera vuelos de cabotaje dentro de Argentina. En días tranquilos, el sistema de reservas funciona sin demasiados problemas. Pero cuando un vuelo empieza a llenarse —por ejemplo, un viernes a la tarde rumbo a Bariloche o un fin de semana largo con destino a Iguazú— empiezan a aparecer situaciones más interesantes: varios pasajeros quieren los mismos asientos, algunas reservas quedan pendientes de confirmación, otras se cancelan, y además hay tareas auxiliares que el sistema tiene que disparar sin frenar toda la operatoria.

La empresa quiere rehacer una versión simplificada de ese sistema para entender mejor cómo modelar concurrencia, estado y coordinación entre procesos.

El problema es bastante concreto: si el sistema está mal diseñado, aparecen errores clásicos como estos:

* dos pasajeros creen que reservaron el mismo asiento
* una reserva queda a medio confirmar
* una cancelación libera mal un asiento
* una tarea auxiliar tarda demasiado y bloquea todo

La idea de este TP es construir una versión simplificada pero razonable de ese sistema usando procesos manuales en Elixir, sin usar todavía OTP.

No buscamos hacer “un sistema real de aerolínea”. El foco está en construir un sistema concurrente chico pero bien diseñado, donde se vea con claridad:

* modelado de dominio
* procesos con estado
* procesos para tareas puntuales
* comunicación por mensajes
* consistencia frente a concurrencia

⸻

Objetivo

Diseñar e implementar un sistema por CLI que simule la reserva de asientos para un vuelo y que permita mostrar concurrencia real sobre recursos limitados.

El proyecto debe crearse con mix, pero sin supervisor:

mix new condor_del_sur --no-sup

No deben usar GenServer, Supervisor, Task, Agent, Registry ni behaviours de OTP.

⸻

Qué tiene que hacer el sistema

Como mínimo, el sistema debe permitir:

* crear o cargar un vuelo con asientos
* registrar pasajeros
* consultar asientos disponibles
* iniciar una reserva sobre un asiento específico
* confirmar una reserva mediante un pago
* cancelar una reserva a pedido del usuario, siempre que todavía no haya sido confirmada
* mostrar un estado final claro del vuelo

Además, debe haber un caso donde varios pasajeros compitan por el mismo asiento al mismo tiempo, y el sistema debe resolverlo correctamente.

⸻

Estados y transiciones mínimas

Para este TP, es importante distinguir entre el inicio de una reserva y su cierre.

Estados de la reserva

Una reserva puede estar en alguno de estos estados:

* :pending — la reserva fue iniciada, pero todavía no quedó cerrada
* :confirmed — la reserva fue confirmada mediante un pago
* :cancelled — la reserva fue cancelada por el usuario antes de ser confirmada
* :expired — la reserva venció sin confirmarse dentro de los 30 segundos

Estados del asiento

Un asiento puede estar en alguno de estos estados:

* :available — disponible
* :reserved — asociado a una reserva pendiente
* :confirmed — asignado de manera definitiva

Reglas mínimas esperadas

* cuando una reserva se inicia correctamente:
    * la reserva pasa a :pending
    * el asiento pasa a :reserved
* cuando una reserva se confirma:
    * la reserva pasa a :confirmed
    * el asiento pasa a :confirmed
* cuando una reserva se cancela antes de ser confirmada:
    * la reserva pasa a :cancelled
    * el asiento vuelve a :available
* cuando una reserva no se confirma dentro de los 30 segundos:
    * la reserva pasa a :expired
    * el asiento vuelve a :available

En otras palabras: iniciar una reserva no significa que el asiento quedó asignado para siempre. Significa que el sistema lo bloqueó temporalmente mientras esa reserva está abierta.

⸻

Qué queremos ver en el TP

1. Modelado de dominio

Se espera que modelen un dominio razonable usando módulos y structs.

Entidades mínimas sugeridas:

* Passenger
* Seat
* Reservation
* Flight

Los campos exactos no están fijados de antemano. La idea es que cada estudiante termine de definir el modelo de forma coherente.

2. Procesos centrales del sistema

Tiene que haber 2 o 3 procesos relevantes del sistema.

Por ejemplo:

* un proceso que mantenga el estado principal del vuelo
* un proceso que coordine reservas
* un proceso adicional para auditoría, notificaciones o similar

No es obligatorio usar exactamente esos nombres, pero sí debe haber una separación razonable de responsabilidades.

3. Procesos cliente

Deben existir múltiples procesos que representen pasajeros o clientes del sistema.

Estos procesos tienen que poder competir concurrentemente por recursos del sistema.

4. Procesos para tareas puntuales

Además de los procesos con estado, el sistema debe disparar al menos una tarea en un proceso separado.

Ejemplos posibles:

* escritura a disco
* validación externa simulada
* consulta HTTP
* expiración automática de una reserva
* generación de una confirmación

La idea es mostrar que no todos los procesos viven para siempre: algunos hacen un trabajo y terminan.

5. Uso de herramientas vistas en clase

El TP debe usar explícitamente:

* send / receive
* loop recursivo en procesos con estado
* register en al menos un proceso importante
* monitor en al menos un caso razonable

⸻

Reglas mínimas de negocio

Como mínimo, el sistema debe garantizar que:

* un asiento no puede quedar asignado a dos pasajeros al mismo tiempo
* una reserva pendiente no deja el sistema en un estado inconsistente
* si dos pasajeros intentan reservar el mismo asiento concurrentemente, solo uno lo consigue
* una reserva confirmada ya no puede cancelarse como si siguiera pendiente

⸻

Demo esperada

La entrega debe incluir una demo reproducible por consola.

Esa demo debería mostrar al menos:

* varios pasajeros intentando reservar al mismo tiempo
* competencia por un mismo asiento
* una resolución correcta del conflicto
* al menos un caso de confirmación por pago
* al menos un caso de cancelación antes de confirmar
* al menos un caso de expiración
* ejecución de al menos una tarea auxiliar
* un estado final claro del sistema

La salida de la demo tiene que ser entendible. No alcanza con imprimir mensajes sueltos sin contexto.

⸻

Tests

No esperamos una batería enorme de tests, pero sí algunos tests mínimos bien elegidos.

Conviene testear principalmente la lógica de dominio y las operaciones puras. Por ejemplo:

* iniciar una reserva sobre un asiento disponible
* intentar reservar un asiento ocupado
* confirmar una reserva pendiente
* cancelar una reserva pendiente
* evitar cancelar una reserva ya confirmada
* verificar que una reserva expirada libere el asiento

No hace falta cubrir toda la concurrencia del sistema con tests complejos de punta a punta.

⸻

Entrega

La entrega será a través de un repositorio de GitHub.

El repositorio debe incluir:

* código fuente completo
* README.md
* instrucciones claras para correr el sistema
* explicación breve de qué procesos existen y qué responsabilidad tiene cada uno
* explicación de dónde usan register y monitor
* demo reproducible
* tests mínimos

El README debe explicar claramente:

* cómo compilar el proyecto
* cómo correr la demo
* cómo correr los tests
* qué procesos principales existen

⸻

Qué no hace falta hacer

No hace falta implementar:

* interfaz web o gráfica
* pasarelas de pago reales
* múltiples aeropuertos y escalas
* un sistema completo de tickets aéreos
* persistencia de producción

El foco del TP está en procesos, dominio y concurrencia.

⸻

Criterios de evaluación

Se evaluará principalmente:

* que la demo funcione y sea clara
* que el modelo concurrente sea correcto
* que el dominio esté razonablemente modelado
* que haya buen uso de procesos, mensajes, register y monitor
* que el repositorio esté prolijo y bien documentado
