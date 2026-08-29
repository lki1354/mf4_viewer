/// Data model for a parsed DBC (CAN database) file.
///
/// Only the subset of the DBC format required to decode signals into
/// physical / enumerated values is represented here.
library;

/// Byte order of a signal as encoded in the DBC (`@1` / `@0`).
enum ByteOrder { littleEndian, bigEndian }

/// A single value-to-text entry of an enumeration (`VAL_`).
class EnumTable {
  /// Maps the raw integer value to its textual representation.
  final Map<int, String> entries;

  const EnumTable(this.entries);

  String? text(num value) => entries[value.toInt()];

  bool get isEmpty => entries.isEmpty;
}

/// One signal definition belonging to a [DbcMessage].
class DbcSignal {
  final String name;

  /// Start bit as written in the DBC.
  final int startBit;
  final int bitLength;
  final ByteOrder byteOrder;
  final bool signed;
  final double factor;
  final double offset;
  final double min;
  final double max;
  final String unit;
  final List<String> receivers;

  /// Multiplexing: `null` = plain signal, `-1` = multiplexor switch,
  /// `>=0` = multiplexed signal active for that switch value.
  final int? multiplexValue;
  final bool isMultiplexor;

  /// Enumeration table (from `VAL_`), or `null` if the signal is numeric.
  EnumTable? enumTable;

  DbcSignal({
    required this.name,
    required this.startBit,
    required this.bitLength,
    required this.byteOrder,
    required this.signed,
    required this.factor,
    required this.offset,
    required this.min,
    required this.max,
    required this.unit,
    required this.receivers,
    this.multiplexValue,
    this.isMultiplexor = false,
    this.enumTable,
  });

  /// A signal is plotted on a categorical (text) axis only when it is a
  /// *pure* enumeration: it carries a value table and applies no linear
  /// scaling. Signals that have a real factor/offset (e.g. a frequency in Hz
  /// that merely reserves a sentinel code) are plotted numerically; their
  /// enum text, if any, is still available for tooltips.
  bool get isEnum =>
      enumTable != null &&
      !enumTable!.isEmpty &&
      factor == 1.0 &&
      offset == 0.0;

  /// Whether a value table exists at all (used for tooltip lookups).
  bool get hasEnumTable => enumTable != null && !enumTable!.isEmpty;
}

/// One message (`BO_`) of the database.
class DbcMessage {
  /// Raw arbitration id including the extended-frame flag bit (0x80000000).
  final int rawId;
  final String name;
  final int dlc;
  final String transmitter;
  final List<DbcSignal> signals;

  DbcMessage({
    required this.rawId,
    required this.name,
    required this.dlc,
    required this.transmitter,
    required this.signals,
  });

  /// Arbitration id with the extended flag masked off.
  int get id => isExtended ? (rawId & 0x1FFFFFFF) : (rawId & 0x7FF);

  bool get isExtended => (rawId & 0x80000000) != 0;
}

/// The whole parsed database.
class DbcDatabase {
  final List<DbcMessage> messages;

  /// Index from arbitration id -> message for fast frame lookup.
  final Map<int, DbcMessage> byId;

  DbcDatabase(this.messages) : byId = {for (final m in messages) m.id: m};

  DbcMessage? messageForId(int arbitrationId) => byId[arbitrationId];

  /// Merge several databases into one. Messages are deduplicated by
  /// arbitration id — the first database defining an id wins, so callers
  /// should pass databases in priority order.
  static DbcDatabase merge(Iterable<DbcDatabase> databases) {
    final seen = <int>{};
    final messages = <DbcMessage>[];
    for (final db in databases) {
      for (final m in db.messages) {
        if (seen.add(m.id)) messages.add(m);
      }
    }
    return DbcDatabase(messages);
  }
}
