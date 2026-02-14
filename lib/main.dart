import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/* =======================
  SABİTLER VE AYARLAR
======================= */
const String PRINTER_IP = '192.168.1.1';
const int PRINTER_PORT = 9100;
const String _ADMIN_PIN = '6538';
const int EARLY_TOLERANCE_MIN = 5;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final appState = AppState();
  await appState.loadSettings();
  runApp(AppScope(notifier: appState, child: const App()));
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BISCORNUE',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFFF5722),
          brightness: Brightness.light,
        ),
      ),
      home: const Home(),
    );
  }
}

/* =======================
  MODELLER
======================= */
class OptionItem {
  final String id;
  String label;
  double price;
  OptionItem({required this.id, required this.label, required this.price});

  Map<String, dynamic> toJson() => {'id': id, 'label': label, 'price': price};
  factory OptionItem.fromJson(Map<String, dynamic> j) =>
      OptionItem(id: j['id'], label: j['label'], price: (j['price'] as num).toDouble());
}

class OptionGroup {
  final String id;
  String title;
  bool multiple;
  int minSelect;
  int maxSelect;
  final List<OptionItem> items;
  OptionGroup({
    required this.id,
    required this.title,
    required this.multiple,
    required this.minSelect,
    required this.maxSelect,
    List<OptionItem>? items,
  }) : items = items ?? [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'multiple': multiple,
        'min': minSelect,
        'max': maxSelect,
        'items': items.map((e) => e.toJson()).toList(),
      };
  factory OptionGroup.fromJson(Map<String, dynamic> j) => OptionGroup(
        id: j['id'],
        title: j['title'],
        multiple: j['multiple'] ?? false,
        minSelect: j['min'] ?? 0,
        maxSelect: j['max'] ?? 1,
        items: (j['items'] as List? ?? [])
            .map((e) => OptionItem.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );
}

class Product {
  String name;
  final List<OptionGroup> groups;
  Product({required this.name, List<OptionGroup>? groups}) : groups = groups ?? [];

  double priceForSelection(Map<String, List<OptionItem>> picked) {
    double total = 0;
    for (final g in groups) {
      final list = picked[g.id] ?? const [];
      for (final it in list) total += it.price;
    }
    return total;
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'groups': groups.map((g) => g.toJson()).toList(),
      };
  factory Product.fromJson(Map<String, dynamic> j) => Product(
        name: j['name'],
        groups: (j['groups'] as List? ?? [])
            .map((e) => OptionGroup.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );
}

class CartLine {
  final Product product;
  final Map<String, List<OptionItem>> picked;
  int qty;
  String note; // Müşteri notu eklendi

  CartLine({required this.product, required this.picked, this.qty = 1, this.note = ""});

  double get unitTotal => product.priceForSelection(picked);
  double get total => unitTotal * qty;

  Map<String, dynamic> toJson() => {
        'product': product.toJson(),
        'picked': {for (final e in picked.entries) e.key: e.value.map((it) => it.toJson()).toList()},
        'qty': qty,
        'note': note,
      };
  factory CartLine.fromJson(Map<String, dynamic> j) => CartLine(
        product: Product.fromJson(Map<String, dynamic>.from(j['product'])),
        picked: {
          for (final e in (j['picked'] as Map).entries)
            e.key: (e.value as List).map((x) => OptionItem.fromJson(Map<String, dynamic>.from(x))).toList()
        },
        qty: (j['qty'] as int?) ?? 1,
        note: j['note'] ?? "",
      );
}

class SavedOrder {
  final String id;
  final DateTime createdAt;
  final DateTime readyAt;
  final List<CartLine> lines;
  final String customer;

  SavedOrder({
    required this.id,
    required this.createdAt,
    required this.readyAt,
    required this.lines,
    required this.customer,
  });

  double get total => lines.fold(0.0, (s, l) => s + l.total);

  Map<String, dynamic> toJson() => {
        'id': id,
        'createdAt': createdAt.toIso8601String(),
        'readyAt': readyAt.toIso8601String(),
        'customer': customer,
        'lines': lines.map((l) => l.toJson()).toList(),
      };
  factory SavedOrder.fromJson(Map<String, dynamic> j) => SavedOrder(
        id: j['id'],
        createdAt: DateTime.parse(j['createdAt']),
        readyAt: DateTime.parse(j['readyAt']),
        customer: j['customer'] ?? '',
        lines: (j['lines'] as List).map((e) => CartLine.fromJson(Map<String, dynamic>.from(e))).toList(),
      );
}

/* =======================
  UYGULAMA DURUMU (STATE)
======================= */
class AppState extends ChangeNotifier {
  final List<Product> products = [];
  final List<CartLine> cart = [];
  final List<SavedOrder> orders = [];
  int prepMinutes = 5;
  String printerIp = PRINTER_IP;
  int printerPort = PRINTER_PORT;

  Future<void> loadSettings() async {
    final sp = await SharedPreferences.getInstance();
    prepMinutes = sp.getInt('prepMinutes') ?? 5;
    printerIp = sp.getString('printerIp') ?? PRINTER_IP;
    printerPort = sp.getInt('printerPort') ?? PRINTER_PORT;
    await _loadProducts();
    await _loadOrders();
    notifyListeners();
  }

  Future<void> _saveProducts() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('products_json', jsonEncode(products.map((p) => p.toJson()).toList()));
  }

  Future<void> _loadProducts() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString('products_json');
    if (raw != null) {
      final list = jsonDecode(raw) as List;
      products.clear();
      products.addAll(list.map((e) => Product.fromJson(Map<String, dynamic>.from(e))));
      notifyListeners();
    }
  }

  Future<void> _saveOrders() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('orders_json', jsonEncode(orders.map((o) => o.toJson()).toList()));
  }

  Future<void> _loadOrders() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString('orders_json');
    if (raw != null) {
      final list = jsonDecode(raw) as List;
      orders.clear();
      orders.addAll(list.map((e) => SavedOrder.fromJson(Map<String, dynamic>.from(e))));
      notifyListeners();
    }
  }

  void addProduct(Product p) {
    products.add(p);
    _saveProducts();
    notifyListeners();
  }

  void addLineToCart(Product p, Map<String, List<OptionItem>> picked, String note, {int qty = 1}) {
    cart.add(CartLine(product: p, picked: picked, qty: qty, note: note));
    notifyListeners();
  }

  void removeCartLineAt(int i) {
    cart.removeAt(i);
    notifyListeners();
  }

  // SİPARİŞİ DÜZENLEME (Sepete geri al)
  void restoreOrderToCart(SavedOrder order) {
    cart.addAll(order.lines);
    notifyListeners();
  }

  SavedOrder? finalizeCartToOrder({required String customer, required DateTime readyAt}) {
    if (cart.isEmpty) return null;
    final order = SavedOrder(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      createdAt: DateTime.now(),
      readyAt: readyAt,
      lines: List.from(cart),
      customer: customer,
    );
    orders.add(order);
    cart.clear();
    _saveOrders();
    notifyListeners();
    return order;
  }

  void clearOrders() {
    orders.clear();
    _saveOrders();
    notifyListeners();
  }

  void setPrepMinutes(int m) { prepMinutes = m; notifyListeners(); }
  Future<void> setPrinter(String ip, int port) async {
    printerIp = ip; printerPort = port; notifyListeners();
  }
}

class AppScope extends InheritedNotifier<AppState> {
  const AppScope({required AppState notifier, required Widget child, Key? key})
      : super(key: key, notifier: notifier, child: child);
  static AppState of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
}

/* =======================
  ANA SAYFA (TABS)
======================= */
class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int index = 0;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final pages = [
      const ProductsPage(),
      const CartPage(),
      const OrdersPage(),
      CreateProductPage(onGoToTab: (i) => setState(() => index = i)),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('BISCORNUE POS')),
      body: pages[index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) => setState(() => index = i),
        destinations: [
          const NavigationDestination(icon: Icon(Icons.restaurant_menu), label: 'Produits'),
          NavigationDestination(
            icon: Badge(label: Text('${app.cart.length}'), child: const Icon(Icons.shopping_cart)),
            label: 'Panier',
          ),
          const NavigationDestination(icon: Icon(Icons.receipt_long), label: 'Commandes'),
          const NavigationDestination(icon: Icon(Icons.settings), label: 'Admin'),
        ],
      ),
    );
  }
}

/* =======================
  ÜRÜN SEÇİMİ (TEK SAYFA YAPISI)
======================= */
class ProductSelectionPage extends StatefulWidget {
  final Product product;
  const ProductSelectionPage({super.key, required this.product});

  @override
  State<ProductSelectionPage> createState() => _ProductSelectionPageState();
}

class _ProductSelectionPageState extends State<ProductSelectionPage> {
  final Map<String, List<OptionItem>> picked = {};
  final TextEditingController noteCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Varsayılan seçimleri (min=1 olanları) otomatik seç
    for (var g in widget.product.groups) {
      if (g.minSelect == 1 && !g.multiple) {
        picked[g.id] = [g.items.first];
      }
    }
  }

  void toggleItem(OptionGroup g, OptionItem it) {
    setState(() {
      final list = picked[g.id] ?? [];
      if (g.multiple) {
        if (list.any((e) => e.id == it.id)) {
          list.removeWhere((e) => e.id == it.id);
        } else if (list.length < g.maxSelect) {
          list.add(it);
        }
      } else {
        picked[g.id] = [it];
      }
      picked[g.id] = list;
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.product.name)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var g in widget.product.groups) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(g.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: g.items.map((it) {
                  final isSelected = (picked[g.id] ?? []).any((e) => e.id == it.id);
                  return ChoiceChip(
                    label: Text("${it.label} ${it.price > 0 ? '(+€${it.price})' : ''}"),
                    selected: isSelected,
                    onSelected: (_) => toggleItem(g, it),
                  );
                }).toList(),
              ),
              const Divider(height: 32),
            ],
            const Text("Note pour la cuisine (ex: sans oignon)", style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            TextField(
              controller: noteCtrl,
              decoration: const InputDecoration(border: OutlineInputBorder(), hintText: "Votre message ici..."),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: FilledButton(
                onPressed: () {
                  app.addLineToCart(widget.product, picked, noteCtrl.text);
                  Navigator.pop(context);
                },
                child: const Text("Ajouter au Panier"),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/* =======================
  GELİŞMİŞ SAAT DİYALOĞU
======================= */
class AdvancedTimeDialog extends StatefulWidget {
  final int defaultPrepMinutes;
  const AdvancedTimeDialog({super.key, required this.defaultPrepMinutes});

  @override
  State<AdvancedTimeDialog> createState() => _AdvancedTimeDialogState();
}

class _AdvancedTimeDialogState extends State<AdvancedTimeDialog> {
  late DateTime selectedTime;
  final List<int> quickMinutes = [10, 15, 20, 25, 30, 35, 40, 45, 50, 60];

  @override
  void initState() {
    super.initState();
    selectedTime = DateTime.now().add(Duration(minutes: widget.defaultPrepMinutes));
  }

  void _addMinutes(int m) {
    setState(() {
      selectedTime = DateTime.now().add(Duration(minutes: m));
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text("Heure de retrait"),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            "${selectedTime.hour.toString().padLeft(2, '0')}:${selectedTime.minute.toString().padLeft(2, '0')}",
            style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold, color: Colors.deepOrange),
          ),
          const SizedBox(height: 16),
          const Text("Ajouter des minutes :"),
          const SizedBox(height: 8),
          SizedBox(
            width: 300,
            child: Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: quickMinutes.map((m) => ActionChip(
                label: Text("+$m"),
                onPressed: () => _addMinutes(m),
              )).toList(),
            ),
          ),
          const SizedBox(height: 16),
          TextButton.icon(
            icon: const Icon(Icons.access_time),
            label: const Text("Choisir manuellement"),
            onPressed: () async {
              final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(selectedTime));
              if (t != null) {
                setState(() {
                  final now = DateTime.now();
                  selectedTime = DateTime(now.year, now.month, now.day, t.hour, t.minute);
                });
              }
            },
          )
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text("Annuler")),
        FilledButton(onPressed: () => Navigator.pop(context, selectedTime), child: const Text("Valider")),
      ],
    );
  }
}

/* =======================
  SEPET SAYFASI
======================= */
class CartPage extends StatelessWidget {
  const CartPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    double total = app.cart.fold(0, (sum, item) => sum + item.total);

    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            itemCount: app.cart.length,
            itemBuilder: (context, i) {
              final item = app.cart[i];
              return ListTile(
                title: Text("${item.product.name} x${item.qty} - €${item.total}"),
                subtitle: Text("Note: ${item.note}\nOptions: ${item.picked.values.expand((e) => e).map((e) => e.label).join(', ')}"),
                trailing: IconButton(icon: const Icon(Icons.delete), onPressed: () => app.removeCartLineAt(i)),
              );
            },
          ),
        ),
        Container(
          padding: const EdgeInsets.all(16),
          color: Colors.grey[200],
          child: Column(
            children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                const Text("TOTAL:", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                Text("€${total.toStringAsFixed(2)}", style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              ]),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () async {
                    if (app.cart.isEmpty) return;
                    String? name = await _askName(context);
                    if (name == null) return;
                    DateTime? time = await showDialog<DateTime>(
                      context: context,
                      builder: (_) => AdvancedTimeDialog(defaultPrepMinutes: app.prepMinutes),
                    );
                    if (time == null) return;
                    final order = app.finalizeCartToOrder(customer: name, readyAt: time);
                    if (order != null) {
                      await printOrderAndroidWith(order, app.printerIp, app.printerPort);
                    }
                  },
                  child: const Text("Valider la Commande"),
                ),
              )
            ],
          ),
        )
      ],
    );
  }

  Future<String?> _askName(BuildContext context) => showDialog<String>(
    context: context,
    builder: (ctx) {
      final ctrl = TextEditingController();
      return AlertDialog(
        title: const Text("Nom du client"),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Annuler")),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text("OK")),
        ],
      );
    }
  );
}

/* =======================
  SİPARİŞLER SAYFASI
======================= */
class OrdersPage extends StatelessWidget {
  const OrdersPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final list = app.orders.reversed.toList();

    return ListView.builder(
      itemCount: list.length,
      itemBuilder: (context, i) {
        final o = list[i];
        return Card(
          margin: const EdgeInsets.all(8),
          child: ListTile(
            title: Text("${o.customer} - €${o.total}"),
            subtitle: Text("Prêt à: ${o.readyAt.hour}:${o.readyAt.minute.toString().padLeft(2, '0')}\n${o.lines.length} articles"),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.edit, color: Colors.blue),
                  tooltip: "Modifier / Rétablir",
                  onPressed: () {
                    app.restoreOrderToCart(o);
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Sipariş sepete geri yüklendi.")));
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.print),
                  onPressed: () => printOrderAndroidWith(o, app.printerIp, app.printerPort),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/* =======================
  YAZICI VE UTIL
======================= */
class ProductsPage extends StatelessWidget {
  const ProductsPage({super.key});
  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, childAspectRatio: 1.5, crossAxisSpacing: 10, mainAxisSpacing: 10),
      itemCount: app.products.length,
      itemBuilder: (context, i) => InkWell(
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ProductSelectionPage(product: app.products[i]))),
        child: Container(
          decoration: BoxDecoration(color: Colors.orange[100], borderRadius: BorderRadius.circular(12)),
          child: Center(child: Text(app.products[i].name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
        ),
      ),
    );
  }
}

class CreateProductPage extends StatelessWidget {
  final Function(int) onGoToTab;
  const CreateProductPage({super.key, required this.onGoToTab});
  @override
  Widget build(BuildContext context) { return const Center(child: Text("Yazılım Ayarları ve Ürün Ekleme")); }
}

Future<void> printOrderAndroidWith(SavedOrder o, String ip, int port) async {
  try {
    final socket = await Socket.connect(ip, port, timeout: const Duration(seconds: 5));
    // ESC/POS Init
    socket.add([27, 64]);
    // Başlık
    socket.write("\n*** BISCORNUE ***\n");
    socket.write("Client: ${o.customer}\n");
    socket.write("Pret a: ${o.readyAt.hour}:${o.readyAt.minute.toString().padLeft(2, '0')}\n");
    socket.write("--------------------------------\n");
    
    for (var l in o.lines) {
      socket.write("${l.qty}x ${l.product.name} .... ${l.total}e\n");
      if (l.note.isNotEmpty) socket.write(" !! NOTE: ${l.note}\n");
      for (var pickedItems in l.picked.values) {
        for (var it in pickedItems) {
          socket.write("  - ${it.label}\n");
        }
      }
      socket.write("--\n");
    }
    socket.write("--------------------------------\n");
    socket.write("TOTAL: ${o.total} Euro\n\n\n");
    
    // Kesme komutu
    socket.add([29, 86, 66, 0]);
    await socket.flush();
    await socket.close();
  } catch (e) {
    print("Yazıcı hatası: $e");
  }
}
