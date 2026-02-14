import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/* =======================
  CONSTANTES
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
  MODÈLES & ÉTAT
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
  String note; // Ajout de la note client

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
    if (raw != null && raw.isNotEmpty) {
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
    if (raw != null && raw.isNotEmpty) {
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

  void replaceProductAt(int i, Product p) {
    products[i] = p;
    _saveProducts();
    notifyListeners();
  }

  void addLineToCart(Product p, Map<String, List<OptionItem>> picked, String note, {int qty = 1}) {
    cart.add(CartLine(product: p, picked: picked, qty: qty, note: note));
    notifyListeners();
  }

  void restoreOrderToCart(SavedOrder order) {
    cart.addAll(order.lines);
    notifyListeners();
  }

  void updateCartLineQty(int i, int newQty) {
    if (i < 0 || i >= cart.length) return;
    if (newQty < 1) newQty = 1;
    final l = cart[i];
    cart[i] = CartLine(product: l.product, picked: l.picked, qty: newQty, note: l.note);
    notifyListeners();
  }

  void removeCartLineAt(int i) {
    if (i >= 0 && i < cart.length) {
      cart.removeAt(i);
      notifyListeners();
    }
  }

  void clearCart() {
    cart.clear();
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

  Future<void> setPrepMinutes(int m) async {
    prepMinutes = m;
    final sp = await SharedPreferences.getInstance();
    await sp.setInt('prepMinutes', m);
    notifyListeners();
  }

  Future<void> setPrinter(String ip, int port) async {
    printerIp = ip;
    printerPort = port;
    final sp = await SharedPreferences.getInstance();
    await sp.setString('printerIp', ip);
    await sp.setInt('printerPort', port);
    notifyListeners();
  }
}

class AppScope extends InheritedNotifier<AppState> {
  const AppScope({required AppState notifier, required Widget child, Key? key})
      : super(key: key, notifier: notifier, child: child);
  static AppState of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
}

/* =======================
  DATA HELPERS (FRENCH)
======================= */
List<OptionItem> _meats(double base) => [
      OptionItem(id: 'kebab', label: 'Kebab', price: base),
      OptionItem(id: 'steak', label: 'Steak hache maison', price: base),
      OptionItem(id: 'poulet_curry', label: 'Poulet curry maison', price: base),
      OptionItem(id: 'tenders', label: 'Tenders', price: base),
      OptionItem(id: 'cordon', label: 'Cordon bleu', price: base),
      OptionItem(id: 'nuggets', label: 'Nuggets', price: base),
    ];
List<OptionItem> _supps() => [
      OptionItem(id: 'cheddar', label: 'Cheddar', price: 1.50),
      OptionItem(id: 'mozza', label: 'Mozzarella rapee', price: 1.50),
      OptionItem(id: 'feta', label: 'Feta', price: 1.50),
      OptionItem(id: 'porc', label: 'Poitrine de porc fume', price: 1.50),
      OptionItem(id: 'chevre', label: 'Chevre', price: 1.50),
      OptionItem(id: 'legumes', label: 'Legumes grilles', price: 1.50),
      OptionItem(id: 'oeuf', label: 'Oeuf', price: 1.50),
      OptionItem(id: 'd_cheddar', label: 'Double Cheddar', price: 3.00),
      OptionItem(id: 'd_mozza', label: 'Double Mozzarella rapee', price: 3.00),
      OptionItem(id: 'd_porc', label: 'Double Poitrine de porc fume', price: 3.00),
    ];
List<OptionItem> _sauces() => [
      OptionItem(id: 'sans_sauce', label: 'Sans sauce', price: 0.00),
      OptionItem(id: 'blanche', label: 'Blanche', price: 0.00),
      OptionItem(id: 'ketchup', label: 'Ketchup', price: 0.00),
      OptionItem(id: 'mayo', label: 'Mayonnaise', price: 0.00),
      OptionItem(id: 'algerienne', label: 'Algérienne', price: 0.00),
      OptionItem(id: 'bbq', label: 'Barbecue', price: 0.00),
      OptionItem(id: 'bigburger', label: 'Big Burger', price: 0.00),
      OptionItem(id: 'harissa', label: 'Harissa', price: 0.00),
    ];
List<OptionItem> _tacosSauces() => [
      ..._sauces(),
      OptionItem(id: 'fromagere', label: 'Sauce fromagere', price: 0.00),
      OptionItem(id: 'seulement_fromagere', label: 'Seulement sauce fromagere', price: 0.00),
      OptionItem(id: 'sans_fromagere', label: 'Sans sauce fromagere', price: 0.00),
    ];
List<OptionItem> _formules() => [
      OptionItem(id: 'seul', label: 'Seul', price: 0.00),
      OptionItem(id: 'frites', label: 'Avec frites', price: 1.00),
      OptionItem(id: 'boisson', label: 'Avec boisson', price: 1.00),
      OptionItem(id: 'menu', label: 'Avec frites et boisson', price: 2.00),
    ];

/* =======================
  ACCUEIL (TABS)
======================= */
class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  bool _seeded = false;
  int index = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_seeded) return;
    _seeded = true;
    final app = AppScope.of(context);
    if (app.products.isEmpty) {
      app.products.addAll([
        Product(name: 'Sandwich', groups: [
          OptionGroup(id: 'type_sand', title: 'Sandwich', multiple: false, minSelect: 1, maxSelect: 1, items: [
            OptionItem(id: 'kebab', label: 'Kebab', price: 10.00),
            OptionItem(id: 'curryosite', label: 'La Curryosite', price: 10.00),
            OptionItem(id: 'vege', label: 'Vegetarien', price: 10.00),
            OptionItem(id: 'berlineur', label: 'Berlineur', price: 12.00),
          ]),
          OptionGroup(id: 'pain', title: 'Pain', multiple: false, minSelect: 1, maxSelect: 1, items: [
            OptionItem(id: 'pita', label: 'Pain pita', price: 0.00),
            OptionItem(id: 'galette', label: 'Galette', price: 0.00),
          ]),
          OptionGroup(id: 'crudites', title: 'Crudites / Retirer', multiple: true, minSelect: 0, maxSelect: 4, items: [
            OptionItem(id: 'avec_crudites', label: 'Avec crudités', price: 0.00),
            OptionItem(id: 'sans_crudites', label: 'Sans crudités', price: 0.00),
            OptionItem(id: 'sans_tomates', label: 'Sans tomates', price: 0.00),
            OptionItem(id: 'sans_salade', label: 'Sans salade', price: 0.00),
            OptionItem(id: 'sans_oignons', label: 'Sans oignons', price: 0.00),
          ]),
          OptionGroup(id: 'supp', title: 'Supplements', multiple: true, minSelect: 0, maxSelect: 3, items: _supps()),
          OptionGroup(id: 'sauces', title: 'Sauces', multiple: true, minSelect: 1, maxSelect: 2, items: _sauces()),
          OptionGroup(id: 'formule', title: 'Accompagnement', multiple: false, minSelect: 1, maxSelect: 1, items: _formules()),
        ]),
        Product(name: 'Tacos', groups: [
          OptionGroup(id: 'type_tacos', title: 'Taille', multiple: false, minSelect: 1, maxSelect: 1, items: [
            OptionItem(id: 't1', label: '1 viande', price: 10.00),
            OptionItem(id: 't2', label: '2 viandes', price: 12.00),
            OptionItem(id: 't3', label: '3 viandes', price: 14.00),
          ]),
          OptionGroup(id: 'viande1', title: 'Viande 1', multiple: false, minSelect: 1, maxSelect: 1, items: _meats(0.00)),
          OptionGroup(id: 'viande2', title: 'Viande 2', multiple: false, minSelect: 1, maxSelect: 1, items: _meats(0.00)),
          OptionGroup(id: 'viande3', title: 'Viande 3', multiple: false, minSelect: 1, maxSelect: 1, items: _meats(0.00)),
          OptionGroup(id: 'supp_tacos', title: 'Supplements', multiple: true, minSelect: 0, maxSelect: 3, items: _supps()),
          OptionGroup(id: 'sauce_tacos', title: 'Sauces', multiple: true, minSelect: 1, maxSelect: 2, items: _tacosSauces()),
          OptionGroup(id: 'formule_tacos', title: 'Accompagnement', multiple: false, minSelect: 1, maxSelect: 1, items: _formules()),
        ]),
        Product(name: 'Burgers', groups: [
          OptionGroup(id: 'type_burger', title: 'Burger', multiple: false, minSelect: 1, maxSelect: 1, items: [
            OptionItem(id: 'la_biquette', label: 'La Biquette', price: 12.00),
            OptionItem(id: 'le_majestueux', label: 'Le Majestueux', price: 12.00),
            OptionItem(id: 'totoro', label: 'TOTORO', price: 13.00),
          ]),
          OptionGroup(id: 'sauce_burger', title: 'Sauces', multiple: true, minSelect: 1, maxSelect: 2, items: _sauces()),
          OptionGroup(id: 'formule_burger', title: 'Accompagnement', multiple: false, minSelect: 1, maxSelect: 1, items: _formules()),
        ]),
        Product(name: 'Menu Enfant', groups: [
          OptionGroup(id: 'choix_enfant', title: 'Choix', multiple: false, minSelect: 1, maxSelect: 1, items: [
            OptionItem(id: 'cheese_menu', label: 'Cheeseburger avec frites', price: 7.90),
            OptionItem(id: 'nuggets_menu', label: '5 Nuggets et frites', price: 7.90),
          ]),
          OptionGroup(id: 'crudites_enfant', title: 'Crudites', multiple: true, minSelect: 0, maxSelect: 3, items: [
            OptionItem(id: 'avec', label: 'Avec crudités', price: 0.00),
            OptionItem(id: 'sans_tomates', label: 'Sans tomates', price: 0.00),
            OptionItem(id: 'sans_salade', label: 'Sans salade', price: 0.00),
          ]),
          OptionGroup(id: 'sauce_enfant', title: 'Sauces', multiple: true, minSelect: 1, maxSelect: 2, items: _sauces()),
          OptionGroup(id: 'boisson_enfant', title: 'Boisson', multiple: false, minSelect: 1, maxSelect: 1, items: [
            OptionItem(id: 'sans_boisson', label: 'Sans boisson', price: 0.00),
            OptionItem(id: 'avec_boisson', label: 'Avec boisson', price: 1.00),
          ]),
        ]),
        Product(name: 'Petit Faim', groups: [
          OptionGroup(id: 'choix_pf', title: 'Choix', multiple: false, minSelect: 1, maxSelect: 1, items: [
            OptionItem(id: 'frites_p', label: 'Frites petite portion', price: 3.00),
            OptionItem(id: 'frites_g', label: 'Frites grande portion', price: 6.00),
            OptionItem(id: 'tenders3', label: '3 Tenders', price: 5.00),
            OptionItem(id: 'tenders6', label: '6 Tenders', price: 10.00),
            OptionItem(id: 'nuggets6', label: '6 Nuggets', price: 4.00),
            OptionItem(id: 'nuggets12', label: '12 Nuggets', price: 8.00),
          ]),
          OptionGroup(id: 'sauce_pf', title: 'Sauces', multiple: true, minSelect: 1, maxSelect: 2, items: _sauces()),
        ]),
      ]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final pages = [
      const ProductsPage(),
      const CartPage(),
      const OrdersPage(),
      const Center(child: Text("Paramètres Admin")),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('BISCORNUE')),
      body: pages[index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) => setState(() => index = i),
        destinations: [
          const NavigationDestination(icon: Icon(Icons.grid_view_rounded), label: 'Produits'),
          NavigationDestination(
            icon: Badge(label: Text('${app.cart.length}'), child: const Icon(Icons.shopping_bag_outlined)),
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
  PAGE PRODUITS
======================= */
class ProductsPage extends StatelessWidget {
  const ProductsPage({super.key});
  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, childAspectRatio: 1.4, crossAxisSpacing: 16, mainAxisSpacing: 16),
      itemCount: app.products.length,
      itemBuilder: (_, i) => InkWell(
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ProductSelectionPage(product: app.products[i]))),
        child: Ink(
          decoration: BoxDecoration(color: Colors.orange.shade50, borderRadius: BorderRadius.circular(24)),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.fastfood, color: Colors.deepOrange),
              const SizedBox(height: 8),
              Text(app.products[i].name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      ),
    );
  }
}

/* =======================
  SÉLECTION PRODUIT (ONE PAGE)
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
    for (var g in widget.product.groups) {
      if (g.minSelect == 1 && !g.multiple) picked[g.id] = [g.items.first];
    }
  }

  void _onToggle(OptionGroup g, OptionItem it) {
    setState(() {
      final list = List<OptionItem>.from(picked[g.id] ?? []);
      if (g.multiple) {
        if (list.any((e) => e.id == it.id)) {
          list.removeWhere((e) => e.id == it.id);
        } else if (list.length < g.maxSelect) {
          list.add(it);
        }
      } else {
        list.clear();
        list.add(it);
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
              Text(g.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: g.items.map((it) {
                  final sel = (picked[g.id] ?? []).any((e) => e.id == it.id);
                  return ChoiceChip(
                    label: Text("${it.label} ${it.price > 0 ? '(+€${it.price})' : ''}"),
                    selected: sel,
                    onSelected: (_) => _onToggle(g, it),
                  );
                }).toList(),
              ),
              const Divider(height: 32),
            ],
            const Text("Note pour la cuisine (ex: sans oignon)", style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            TextField(
              controller: noteCtrl,
              decoration: const InputDecoration(border: OutlineInputBorder(), hintText: "Votre message..."),
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
  DIALOGUE HEURE AVANCÉ
======================= */
class AdvancedTimeDialog extends StatefulWidget {
  final int defaultMin;
  const AdvancedTimeDialog({super.key, required this.defaultMin});
  @override
  State<AdvancedTimeDialog> createState() => _AdvancedTimeDialogState();
}

class _AdvancedTimeDialogState extends State<AdvancedTimeDialog> {
  late DateTime selected;
  final List<int> quicks = [10, 15, 20, 25, 30, 35, 40, 45, 50, 60];

  @override
  void initState() {
    super.initState();
    selected = DateTime.now().add(Duration(minutes: widget.defaultMin));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text("Heure de retrait"),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text("${selected.hour.toString().padLeft(2,'0')}:${selected.minute.toString().padLeft(2,'0')}", 
               style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold, color: Colors.deepOrange)),
          const SizedBox(height: 16),
          const Text("Ajouter des minutes :"),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: quicks.map((m) => ActionChip(label: Text("+$m"), onPressed: () => setState(() => selected = DateTime.now().add(Duration(minutes: m))))).toList(),
          ),
          const SizedBox(height: 16),
          TextButton.icon(
            icon: const Icon(Icons.access_time),
            label: const Text("Choisir Manuellement"),
            onPressed: () async {
              final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(selected));
              if (t != null) setState(() => selected = DateTime(selected.year, selected.month, selected.day, t.hour, t.minute));
            },
          )
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text("Annuler")),
        FilledButton(onPressed: () => Navigator.pop(context, selected), child: const Text("Valider")),
      ],
    );
  }
}

/* =======================
  PAGE PANIER
======================= */
class CartPage extends StatelessWidget {
  const CartPage({super.key});
  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final total = app.cart.fold(0.0, (s, l) => s + l.total);

    if (app.cart.isEmpty) return const Center(child: Text("Panier vide"));

    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            itemCount: app.cart.length,
            itemBuilder: (context, i) {
              final l = app.cart[i];
              return ListTile(
                title: Text("${l.product.name} x${l.qty}"),
                subtitle: Text("Note: ${l.note}\n${l.picked.values.expand((e)=>e).map((e)=>e.label).join(', ')}"),
                trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => app.removeCartLineAt(i)),
              );
            },
          ),
        ),
        Container(
          padding: const EdgeInsets.all(16),
          color: Colors.grey.shade100,
          child: Column(
            children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                const Text("TOTAL", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                Text("€${total.toStringAsFixed(2)}", style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              ]),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () async {
                    final name = await _askName(context);
                    if (name == null) return;
                    final time = await showDialog<DateTime>(context: context, builder: (_) => AdvancedTimeDialog(defaultMin: app.prepMinutes));
                    if (time == null) return;
                    final order = app.finalizeCartToOrder(customer: name, readyAt: time);
                    if (order != null) await printOrderAndroidWith(order, app.printerIp, app.printerPort);
                  },
                  child: const Text("Valider la Commande"),
                ),
              ),
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
        content: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(hintText: "Écrire le nom")),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Annuler")),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text("OK")),
        ],
      );
    }
  );
}

/* =======================
  PAGE COMMANDES
======================= */
class OrdersPage extends StatelessWidget {
  const OrdersPage({super.key});
  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final orders = app.orders.reversed.toList();

    return ListView.builder(
      itemCount: orders.length,
      itemBuilder: (context, i) {
        final o = orders[i];
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: ListTile(
            title: Text("${o.customer} - €${o.total.toStringAsFixed(2)}"),
            subtitle: Text("Prêt à: ${o.readyAt.hour}:${o.readyAt.minute.toString().padLeft(2, '0')}"),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(icon: const Icon(Icons.edit, color: Colors.blue), onPressed: () {
                  app.restoreOrderToCart(o);
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Commande rétablie dans le panier")));
                }),
                IconButton(icon: const Icon(Icons.print), onPressed: () => printOrderAndroidWith(o, app.printerIp, app.printerPort)),
              ],
            ),
          ),
        );
      },
    );
  }
}

/* =======================
  YAZICI (ESC/POS)
======================= */
Future<void> printOrderAndroidWith(SavedOrder o, String ip, int port) async {
  try {
    final socket = await Socket.connect(ip, port, timeout: const Duration(seconds: 5));
    socket.add([27, 64]); // Init
    socket.write("\n*** BISCORNUE ***\n");
    socket.write("Client: ${o.customer}\n");
    socket.write("Pret a: ${o.readyAt.hour}:${o.readyAt.minute.toString().padLeft(2, '0')}\n");
    socket.write("--------------------------------\n");
    for (var l in o.lines) {
      socket.write("${l.qty}x ${l.product.name} .... ${l.total}e\n");
      if (l.note.isNotEmpty) socket.write(" !! NOTE: ${l.note}\n");
      for (var p in l.picked.values) {
        for (var it in p) socket.write("  - ${it.label}\n");
      }
      socket.write("--\n");
    }
    socket.write("--------------------------------\n");
    socket.write("TOTAL: ${o.total.toStringAsFixed(2)} Euro\n\n\n");
    socket.add([29, 86, 66, 0]); // Cut
    await socket.flush();
    await socket.close();
  } catch (e) {
    print("Printer error: $e");
  }
}
