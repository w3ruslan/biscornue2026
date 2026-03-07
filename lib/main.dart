import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/* =======================
  Sabitler
  ======================= */
const String PRINTER_IP = '192.168.1.1'; // <-- Epson yazıcının IP'si
const int PRINTER_PORT = 9100;           // Genelde 9100 (RAW)
const String _ADMIN_PIN = '6538';
const int EARLY_TOLERANCE_MIN = 5; 

/* =======================
  ENTRY
  ======================= */
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
          seedColor: const Color(0xFFFF5722), // Deep Orange 500
          brightness: Brightness.light,
        ),
      ),
      home: const Home(),
    );
  }
}

/* =======================
  MODELLER & STATE
  ======================= */
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
  factory OptionGroup.fromJson(Map<String, dynamic> j) {
    bool isMulti = j['multiple'] ?? false;
    return OptionGroup(
      id: j['id'],
      title: j['title'],
      multiple: isMulti,
      minSelect: j['min'] ?? 0,
      maxSelect: isMulti ? 99 : (j['max'] ?? 1),
      items: (j['items'] as List? ?? [])
          .map((e) => OptionItem.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
    );
  }
}

class OptionItem {
  final String id;
  String label;
  double price;
  OptionItem({required this.id, required this.label, required this.price});
  Map<String, dynamic> toJson() => {'id': id, 'label': label, 'price': price};
  factory OptionItem.fromJson(Map<String, dynamic> j) =>
      OptionItem(id: j['id'], label: j['label'], price: (j['price'] as num).toDouble());
}

class CartLine {
  final Product product;
  final Map<String, List<OptionItem>> picked;
  int qty;
  final String note;

  CartLine({
    required this.product,
    required this.picked,
    this.qty = 1,
    this.note = '',
  });

  double get unitTotal => product.priceForSelection(picked);
  double get total => unitTotal * qty;

  Map<String, dynamic> toJson() => {
        'product': product.toJson(),
        'picked': {
          for (final e in picked.entries) e.key: e.value.map((it) => it.toJson()).toList()
        },
        'qty': qty,
        'note': note,
      };

  factory CartLine.fromJson(Map<String, dynamic> j) => CartLine(
        product: Product.fromJson(Map<String, dynamic>.from(j['product'])),
        picked: {
          for (final e in (j['picked'] as Map).entries)
            e.key: (e.value as List)
                .map((x) => OptionItem.fromJson(Map<String, dynamic>.from(x)))
                .toList()
        },
        qty: (j['qty'] as int?) ?? 1,
        note: j['note'] ?? '',
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
        lines: (j['lines'] as List)
            .map((e) => CartLine.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );
}

class AppState extends ChangeNotifier {
  final List<Product> products = [];
  final List<CartLine> cart = [];
  final List<SavedOrder> orders = [];
  int prepMinutes = 5;
  String printerIp = PRINTER_IP;
  int printerPort = PRINTER_PORT;

  Future<void> _saveProducts() async {
    final sp = await SharedPreferences.getInstance();
    final data = products.map((p) => p.toJson()).toList();
    await sp.setString('products_json', jsonEncode(data));
  }

  Future<void> _loadProducts() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString('products_json');
    if (raw != null && raw.isNotEmpty) {
      final list = jsonDecode(raw) as List;
      products
        ..clear()
        ..addAll(list.map((e) => Product.fromJson(Map<String, dynamic>.from(e))));
      notifyListeners();
    }
  }

  Future<void> _saveOrders() async {
    final sp = await SharedPreferences.getInstance();
    final data = orders.map((o) => o.toJson()).toList();
    await sp.setString('orders_json', jsonEncode(data));
  }
  Future<void> _loadOrders() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString('orders_json');
    if (raw != null && raw.isNotEmpty) {
      final list = jsonDecode(raw) as List;
      orders
        ..clear()
        ..addAll(list.map((e) => SavedOrder.fromJson(Map<String, dynamic>.from(e))));
      notifyListeners();
    }
  }
  Future<void> loadSettings() async {
    final sp = await SharedPreferences.getInstance();
    prepMinutes = sp.getInt('prepMinutes') ?? 5;
    printerIp = sp.getString('printerIp') ?? PRINTER_IP;
    printerPort = sp.getInt('printerPort') ?? PRINTER_PORT;
    await _loadProducts(); 
    await _loadOrders();
    notifyListeners();
  }
  Future<void> setPrepMinutes(int m) async {
    prepMinutes = m;
    final sp = await SharedPreferences.getInstance();
    await sp.setInt('prepMinutes', m);
    notifyListeners();
  }
  Future<void> setPrinter(String ip, int port) async {
    printerIp = ip.trim();
    printerPort = port;
    final sp = await SharedPreferences.getInstance();
    await sp.setString('printerIp', printerIp);
    await sp.setInt('printerPort', printerPort);
    notifyListeners();
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
  void addLineToCart(Product p, Map<String, List<OptionItem>> picked, {int qty = 1, String note = ''}) {
    final deep = {for (final e in picked.entries) e.key: List<OptionItem>.from(e.value)};
    cart.add(CartLine(product: p, picked: deep, qty: qty, note: note));
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
  void updateCartLineAt(int i, Map<String, List<OptionItem>> picked, String note) {
    if (i < 0 || i >= cart.length) return;
    final deep = {for (final e in picked.entries) e.key: List<OptionItem>.from(e.value)};
    final p = cart[i].product;
    final currentQty = cart[i].qty;
    cart[i] = CartLine(product: p, picked: deep, qty: currentQty, note: note);
    notifyListeners();
  }
  SavedOrder? finalizeCartToOrder({
    required String customer,
    DateTime? readyAtOverride,
  }) {
    if (cart.isEmpty) return null;
    final deepLines = cart
        .map((l) => CartLine(
              product: l.product,
              picked: {for (final e in l.picked.entries) e.key: List<OptionItem>.from(e.value)},
              qty: l.qty,
              note: l.note,
            ))
        .toList();
    final now = DateTime.now();
    final ready = readyAtOverride ?? now.add(Duration(minutes: prepMinutes));
    final order = SavedOrder(
      id: now.millisecondsSinceEpoch.toString(),
      createdAt: now,
      readyAt: ready,
      lines: deepLines,
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
}

/* Ortak listeler (menü data helpers) */
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

class AppScope extends InheritedNotifier<AppState> {
  const AppScope({required AppState notifier, required Widget child, Key? key})
      : super(key: key, notifier: notifier, child: child);
  static AppState of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    return scope!.notifier!;
  }
}

/* =======================
  HOME (4 sekme)
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
      final products = <Product>[
        Product(name: 'Sandwich', groups: [
          OptionGroup(
            id: 'type_sand', title: 'Sandwich', multiple: false, minSelect: 1, maxSelect: 1,
            items: [
              OptionItem(id: 'kebab', label: 'Kebab', price: 10.00),
              OptionItem(id: 'curryosite', label: 'La Curryosite', price: 10.00),
              OptionItem(id: 'vege', label: 'Vegetarien', price: 10.00),
              OptionItem(id: 'berlineur', label: 'Berlineur', price: 12.00),
            ],
          ),
          OptionGroup(id: 'pain', title: 'Pain', multiple: false, minSelect: 1, maxSelect: 1, items: [
            OptionItem(id: 'pita', label: 'Pain pita', price: 0.00),
            OptionItem(id: 'galette', label: 'Galette', price: 0.00),
          ]),
          OptionGroup(id: 'crudites', title: 'Crudites / Retirer', multiple: true, minSelect: 0, maxSelect: 99, items: [
            OptionItem(id: 'avec_crudites', label: 'Avec crudités', price: 0.00),
            OptionItem(id: 'sans_crudites', label: 'Sans crudités', price: 0.00),
            OptionItem(id: 'sans_tomates', label: 'Sans tomates', price: 0.00),
            OptionItem(id: 'sans_salade', label: 'Sans salade', price: 0.00),
            OptionItem(id: 'sans_oignons', label: 'Sans oignons', price: 0.00),
          ]),
          OptionGroup(id: 'supp', title: 'Supplements', multiple: true, minSelect: 0, maxSelect: 99, items: _supps()),
          OptionGroup(id: 'sauces', title: 'Sauces', multiple: true, minSelect: 1, maxSelect: 99, items: _sauces()),
          OptionGroup(id: 'formule', title: 'Accompagnement', multiple: false, minSelect: 1, maxSelect: 1, items: _formules()),
        ]),
        Product(name: 'Tacos', groups: [
          OptionGroup(
            id: 'type_tacos', title: 'Taille', multiple: false, minSelect: 1, maxSelect: 1,
            items: [
              OptionItem(id: 't1', label: '1 viande', price: 10.00),
              OptionItem(id: 't2', label: '2 viandes', price: 12.00),
              OptionItem(id: 't3', label: '3 viandes', price: 14.00),
            ],
          ),
          OptionGroup(id: 'viande1', title: 'Viande 1', multiple: false, minSelect: 1, maxSelect: 1, items: _meats(0.00)),
          OptionGroup(id: 'viande2', title: 'Viande 2', multiple: false, minSelect: 1, maxSelect: 1, items: _meats(0.00)),
          OptionGroup(id: 'viande3', title: 'Viande 3', multiple: false, minSelect: 1, maxSelect: 1, items: _meats(0.00)),
          OptionGroup(id: 'supp_tacos', title: 'Supplements', multiple: true, minSelect: 0, maxSelect: 99, items: _supps()),
          OptionGroup(id: 'sauce_tacos', title: 'Sauces', multiple: true, minSelect: 1, maxSelect: 99, items: _tacosSauces()),
          OptionGroup(id: 'formule_tacos', title: 'Accompagnement', multiple: false, minSelect: 1, maxSelect: 1, items: _formules()),
        ]),
        Product(name: 'Burgers', groups: [
          OptionGroup(
            id: 'type_burger', title: 'Burger', multiple: false, minSelect: 1, maxSelect: 1,
            items: [
              OptionItem(id: 'la_biquette', label: 'La Biquette', price: 12.00),
              OptionItem(id: 'le_majestueux', label: 'Le Majestueux', price: 12.00),
              OptionItem(id: 'totoro', label: 'TOTORO', price: 13.00),
            ],
          ),
          OptionGroup(id: 'sauce_burger', title: 'Sauces', multiple: true, minSelect: 1, maxSelect: 99, items: _sauces()),
          OptionGroup(id: 'formule_burger', title: 'Accompagnement', multiple: false, minSelect: 1, maxSelect: 1, items: _formules()),
        ]),
        Product(name: 'Menu Enfant', groups: [
          OptionGroup(
            id: 'choix_enfant', title: 'Choix', multiple: false, minSelect: 1, maxSelect: 1,
            items: [
              OptionItem(id: 'cheese_menu', label: 'Cheeseburger avec frites', price: 7.90),
              OptionItem(id: 'nuggets_menu', label: '5 Nuggets et frites', price: 7.90),
            ],
          ),
          OptionGroup(id: 'crudites_enfant', title: 'Crudites', multiple: true, minSelect: 0, maxSelect: 99, items: [
              OptionItem(id: 'avec', label: 'Avec crudités', price: 0.00),
              OptionItem(id: 'sans_tomates', label: 'Sans tomates', price: 0.00),
              OptionItem(id: 'sans_salade', label: 'Sans salade', price: 0.00),
          ]),
          OptionGroup(id: 'sauce_enfant', title: 'Sauces', multiple: true, minSelect: 1, maxSelect: 99, items: _sauces()),
          OptionGroup(
            id: 'boisson_enfant', title: 'Boisson', multiple: false, minSelect: 1, maxSelect: 1,
            items: [
              OptionItem(id: 'sans_boisson', label: 'Sans boisson', price: 0.00),
              OptionItem(id: 'avec_boisson', label: 'Avec boisson', price: 1.00),
            ],
          ),
        ]),
        Product(name: 'Petit Faim', groups: [
          OptionGroup(
            id: 'choix_pf', title: 'Choix', multiple: false, minSelect: 1, maxSelect: 1,
            items: [
              OptionItem(id: 'frites_p', label: 'Frites petite portion', price: 3.00),
              OptionItem(id: 'frites_g', label: 'Frites grande portion', price: 6.00),
              OptionItem(id: 'tenders3', label: '3 Tenders', price: 5.00),
              OptionItem(id: 'tenders6', label: '6 Tenders', price: 10.00),
              OptionItem(id: 'nuggets6', label: '6 Nuggets', price: 4.00),
              OptionItem(id: 'nuggets12', label: '12 Nuggets', price: 8.00),
            ],
          ),
          OptionGroup(id: 'sauce_pf', title: 'Sauces', multiple: true, minSelect: 1, maxSelect: 99, items: _sauces()),
        ]),
      ];
      app.products.addAll(products);
    }
  }
  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final totalCart = app.cart.fold(0.0, (s, l) => s + l.total);
    final cartBadge = app.cart.length;
    final pages = [
      const ProductsPage(),
      const CartPage(),
      const OrdersPage(),
      CreateProductPage(onGoToTab: (i) => setState(() => index = i)),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('BISCORNUE')),
      body: pages[index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        destinations: [
          const NavigationDestination(icon: Icon(Icons.grid_view_rounded), label: 'Produits'),
          NavigationDestination(
            icon: Stack(
              clipBehavior: Clip.none,
              children: [
                const Icon(Icons.shopping_bag_outlined),
                if (cartBadge > 0)
                  Positioned(
                    right: -6, top: -6,
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.red),
                      child: Text('$cartBadge', style: const TextStyle(fontSize: 10, color: Colors.white)),
                    ),
                  ),
              ],
            ),
            label: 'Panier (€${totalCart.toStringAsFixed(2)})',
          ),
          const NavigationDestination(icon: Icon(Icons.receipt_long), label: 'Commandes'),
          const NavigationDestination(icon: Icon(Icons.add_box_outlined), label: 'Créer'),
        ],
        onDestinationSelected: (i) async {
          if (i == 3) {
            final ok = await _askPin(context);
            if (!ok) return;
          }
          if (i == 1) {
            ScaffoldMessenger.of(context).hideCurrentSnackBar();
          }
          setState(() => index = i);
        },
      ),
    );
  }
}

/* =======================
  PAGE 1 : PRODUITS
  ======================= */
class ProductsPage extends StatelessWidget {
  const ProductsPage({super.key});
  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final products = app.products;
    if (products.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: const [
          Icon(Icons.info_outline, size: 48),
          SizedBox(height: 8),
          Text('Aucun produit. Allez à "Créer" pour en ajouter.'),
        ]),
      );
    }
    final width = MediaQuery.of(context).size.width;
    int cross = 2;
    if (width > 600) cross = 3;
    if (width > 900) cross = 4;
    final aspect = width > 900 ? 1.40 : (width > 600 ? 1.30 : 1.10);
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cross,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
        childAspectRatio: aspect,
      ),
      itemCount: products.length,
      itemBuilder: (_, i) => _ProductCard(product: products[i]),
    );
  }
}
class _ProductCard extends StatelessWidget {
  final Product product;
  const _ProductCard({super.key, required this.product});
  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme;
    Future<void> openWizard() async {
      final added = await Navigator.push<bool>(
        context,
        MaterialPageRoute(builder: (_) => OrderWizard(product: product)),
      );
      if (added == true && context.mounted) {
        _snack(context, 'Ajouté au panier.');
      }
    }
    return InkWell(
      borderRadius: BorderRadius.circular(24),
      onTap: openWizard,
      child: Ink(
        decoration: BoxDecoration(
          color: color.surfaceVariant,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                height: 32, width: 32,
                decoration: BoxDecoration(
                  color: color.primary.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.fastfood_rounded, color: color.primary, size: 18),
              ),
              const SizedBox(height: 8),
              Text(
                product.name,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/* =======================
  PAGE 2 : CRÉER + DÜZENLE
  ======================= */
class CreateProductPage extends StatefulWidget {
  final void Function(int) onGoToTab;
  final int? editIndex;
  const CreateProductPage({super.key, required this.onGoToTab, this.editIndex});
  @override
  State<CreateProductPage> createState() => _CreateProductPageState();
}

class _CreateProductPageState extends State<CreateProductPage> {
  final TextEditingController nameCtrl = TextEditingController(text: 'Sandwich');
  final List<OptionGroup> editingGroups = [];
  int? editingIndex;
  final TextEditingController delayCtrl = TextEditingController();
  final TextEditingController ipCtrl = TextEditingController();
  final TextEditingController portCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    editingIndex = widget.editIndex;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (editingIndex != null) _loadForEdit(editingIndex!);
      final app = AppScope.of(context);
      delayCtrl.text = app.prepMinutes.toString();
      ipCtrl.text = app.printerIp;
      portCtrl.text = app.printerPort.toString();
    });
  }
  @override
  void dispose() {
    nameCtrl.dispose();
    delayCtrl.dispose();
    ipCtrl.dispose();
    portCtrl.dispose();
    super.dispose();
  }
  void _loadForEdit(int idx) {
    final app = AppScope.of(context);
    if (idx < 0 || idx >= app.products.length) return;
    final p = app.products[idx];
    nameCtrl.text = p.name;
    editingGroups..clear()..addAll(p.groups.map(_copyGroup));
    setState(() => editingIndex = idx);
  }
  OptionGroup _copyGroup(OptionGroup g) => OptionGroup(
        id: g.id,
        title: g.title,
        multiple: g.multiple,
        minSelect: g.minSelect,
        maxSelect: g.maxSelect,
        items: g.items.map((e) => OptionItem(id: e.id, label: e.label, price: e.price)).toList(),
      );
  void addGroup() {
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    editingGroups.add(OptionGroup(id: id, title: 'Nouveau groupe', multiple: false, minSelect: 1, maxSelect: 1));
    setState(() {});
  }
  void saveProduct() {
    final app = AppScope.of(context);
    if (nameCtrl.text.trim().isEmpty) {
      _snack(context, 'Nom du produit requis.');
      return;
    }
    for (final g in editingGroups) {
      if (g.title.trim().isEmpty) {
        _snack(context, 'Titre du groupe manquant.');
        return;
      }
      if (g.items.isEmpty) {
        _snack(context, 'Ajoutez au moins une option dans "${g.title}".');
        return;
      }
      if (g.minSelect < 0 || g.maxSelect < 1 || g.minSelect > g.maxSelect) {
        _snack(context, 'Règles min/max invalides dans "${g.title}".');
        return;
      }
      if (!g.multiple && (g.minSelect != 1 || g.maxSelect != 1)) {
        _snack(context, 'Choix unique doit avoir min=1 et max=1 (${g.title}).');
        return;
      }
    }
    final p = Product(name: nameCtrl.text.trim(), groups: List.of(editingGroups));
    if (editingIndex == null) {
      app.addProduct(p);
      _snack(context, 'Produit créé.');
    } else {
      app.replaceProductAt(editingIndex!, p);
      _snack(context, 'Produit mis à jour.');
    }
    nameCtrl.text = '';
    editingGroups.clear();
    setState(() => editingIndex = null);
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    } else {
      widget.onGoToTab(0);
    }
  }

  bool _isValidIPv4(String s) {
    final reg = RegExp(r'^((25[0-5]|2[0-4]\d|1\d{2}|[1-9]?\d)\.){3}'
            r'(25[0-5]|2[0-4]\d|1\d{2}|[1-9]?\d)$');
    return reg.hasMatch(s);
  }
  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Row(children: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              if (Navigator.of(context).canPop()) {
                Navigator.of(context).pop();
              } else {
                widget.onGoToTab(0);
              }
            },
            tooltip: 'Retour',
          ),
          const SizedBox(width: 8),
          Text(
            editingIndex == null ? 'Créer un produit' : 'Modifier un produit',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const Spacer(),
          TextButton.icon(
            onPressed: () {
              nameCtrl.text = '';
              editingGroups.clear();
              setState(() => editingIndex = null);
              if (Navigator.of(context).canPop()) {
                Navigator.of(context).pop();
              } else {
                widget.onGoToTab(0);
              }
            },
            icon: const Icon(Icons.close),
            label: const Text('Annuler'),
          ),
        ]),
        const SizedBox(height: 12),
        Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: const [
                  Icon(Icons.print_outlined),
                  SizedBox(width: 8),
                  Text('Imprimante', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: ipCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'IP (ex: 192.168.1.50)', border: OutlineInputBorder()),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: portCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Port', border: OutlineInputBorder()),
                    ),
                  ),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  FilledButton.icon(
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('Enregistrer'),
                    onPressed: () async {
                      final ip = ipCtrl.text.trim();
                      final port = int.tryParse(portCtrl.text.trim());
                      if (!_isValidIPv4(ip)) {
                        _snack(context, 'IP invalide. ex : 192.168.1.50');
                        return;
                      }
                      if (port == null || port < 1 || port > 65535) {
                        _snack(context, 'Port invalide (1–65535).');
                        return;
                      }
                      await app.setPrinter(ip, port);
                      _snack(context, 'Imprimante enregistrée: $ip:$port');
                    },
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.print),
                    label: const Text('Tester'),
                    onPressed: () async {
                      final ip = ipCtrl.text.trim();
                      final port = int.tryParse(portCtrl.text.trim());
                      if (!_isValidIPv4(ip) || port == null) return;
                      try {
                        await printTestToPrinter(ip, port);
                        _snack(context, 'Test envoyé.');
                      } catch (e) {
                        _snack(context, 'Échec : $e');
                      }
                    },
                  ),
                ]),
              ],
            ),
          ),
        ),
        Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const Icon(Icons.timer_outlined),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: delayCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Délai prép. (min)', border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () {
                    final m = int.tryParse(delayCtrl.text.trim());
                    if (m != null && m >= 0) {
                      app.setPrepMinutes(m);
                      _snack(context, 'Délai enregistré: $m min');
                    }
                  },
                  child: const Text('Enregistrer'),
                ),
              ],
            ),
          ),
        ),
        if (app.products.isNotEmpty) ...[
          const Text('Produits existants', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: app.products.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final p = app.products[i];
              return ListTile(
                leading: const Icon(Icons.fastfood_rounded),
                title: Text(p.name),
                subtitle: Text('${p.groups.length} groupe(s)'),
                trailing: FilledButton.tonalIcon(
                  icon: const Icon(Icons.edit),
                  label: const Text('Modifier'),
                  onPressed: () => _loadForEdit(i),
                ),
              );
            },
          ),
          const SizedBox(height: 16),
          const Divider(),
          const SizedBox(height: 12),
        ],
        TextField(
          controller: nameCtrl,
          decoration: const InputDecoration(labelText: 'Nom du produit', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        Row(children: [
          FilledButton.icon(onPressed: addGroup, icon: const Icon(Icons.add), label: const Text('Ajouter un groupe')),
          const SizedBox(width: 12),
          OutlinedButton.icon(onPressed: saveProduct, icon: const Icon(Icons.save), label: const Text('Enregistrer')),
        ]),
        const SizedBox(height: 12),
        for (int i = 0; i < editingGroups.length; i++)
          _GroupEditor(
            key: ValueKey(editingGroups[i].id),
            group: editingGroups[i],
            onDelete: () => setState(() => editingGroups.removeAt(i)),
            onChanged: () => setState(() {}),
          ),
      ],
    );
  }
}

class _GroupEditor extends StatefulWidget {
  final OptionGroup group;
  final VoidCallback onDelete;
  final VoidCallback onChanged;
  const _GroupEditor({super.key, required this.group, required this.onDelete, required this.onChanged});
  @override
  State<_GroupEditor> createState() => _GroupEditorState();
}
class _GroupEditorState extends State<_GroupEditor> {
  final TextEditingController titleCtrl = TextEditingController();
  final TextEditingController minCtrl = TextEditingController();
  final TextEditingController maxCtrl = TextEditingController();
  @override
  void initState() {
    super.initState();
    titleCtrl.text = widget.group.title;
    minCtrl.text = widget.group.minSelect.toString();
    maxCtrl.text = widget.group.maxSelect.toString();
  }
  @override
  void dispose() {
    titleCtrl.dispose();
    minCtrl.dispose();
    maxCtrl.dispose();
    super.dispose();
  }
  void apply() {
    widget.group.title = titleCtrl.text.trim();
    widget.group.multiple = _mode == 1;
    widget.group.minSelect = int.tryParse(minCtrl.text) ?? 0;
    widget.group.maxSelect = _mode == 1 ? 99 : (int.tryParse(maxCtrl.text) ?? 1);
    widget.onChanged();
  }
  int get _mode => widget.group.multiple ? 1 : 0;
  set _mode(int v) {
    widget.group.multiple = (v == 1);
    if (v == 0) {
      minCtrl.text = '1';
      maxCtrl.text = '1';
    }
    apply();
    setState(() {});
  }
  void addOption() {
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    widget.group.items.add(OptionItem(id: id, label: 'Nouvelle option', price: 0));
    widget.onChanged();
    setState(() {});
  }
  @override
  Widget build(BuildContext context) {
    final g = widget.group;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          Row(children: [
            Expanded(
              child: TextField(
                controller: titleCtrl,
                decoration: const InputDecoration(labelText: 'Titre du groupe', border: OutlineInputBorder()),
                onChanged: (_) => apply(),
              ),
            ),
            const SizedBox(width: 8),
            DropdownButton<int>(
              value: _mode,
              items: const [
                DropdownMenuItem(value: 0, child: Text('Choix unique')),
                DropdownMenuItem(value: 1, child: Text('Choix multiple')),
              ],
              onChanged: (v) {
                if (v != null) _mode = v;
              },
            ),
            const SizedBox(width: 8),
            IconButton(onPressed: widget.onDelete, icon: const Icon(Icons.delete_outline)),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextField(
                controller: minCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Sélection min', border: OutlineInputBorder()),
                onChanged: (_) => apply(),
              ),
            ),
            const SizedBox(width: 8),
            if (_mode == 0)
              Expanded(
                child: TextField(
                  controller: maxCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Sélection max', border: OutlineInputBorder()),
                  onChanged: (_) => apply(),
                ),
              ),
            if (_mode == 0) const SizedBox(width: 8),
            FilledButton.icon(onPressed: addOption, icon: const Icon(Icons.add), label: const Text('Ajouter une option')),
          ]),
          const SizedBox(height: 8),
          for (int i = 0; i < g.items.length; i++)
            _OptionEditor(
              key: ValueKey(g.items[i].id),
              item: g.items[i],
              onDelete: () {
                g.items.removeAt(i);
                widget.onChanged();
                setState(() {});
              },
              onChanged: () {
                widget.onChanged();
                setState(() {});
              },
            ),
        ]),
      ),
    );
  }
}

class _OptionEditor extends StatefulWidget {
  final OptionItem item;
  final VoidCallback onDelete;
  final VoidCallback onChanged;
  const _OptionEditor({super.key, required this.item, required this.onDelete, required this.onChanged});
  @override
  State<_OptionEditor> createState() => _OptionEditorState();
}
class _OptionEditorState extends State<_OptionEditor> {
  final TextEditingController labelCtrl = TextEditingController();
  final TextEditingController priceCtrl = TextEditingController();
  @override
  void initState() {
    super.initState();
    labelCtrl.text = widget.item.label;
    priceCtrl.text = widget.item.price.toStringAsFixed(2);
  }
  @override
  void dispose() {
    labelCtrl.dispose();
    priceCtrl.dispose();
    super.dispose();
  }
  void apply() {
    widget.item.label = labelCtrl.text.trim();
    widget.item.price = double.tryParse(priceCtrl.text.replaceAll(',', '.')) ?? 0.0;
    widget.onChanged();
  }
  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 0),
      title: Row(children: [
        Expanded(
          child: TextField(
            controller: labelCtrl,
            decoration: const InputDecoration(labelText: 'Nom de l’option', border: OutlineInputBorder()),
            onChanged: (_) => apply(),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 120,
          child: TextField(
            controller: priceCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Prix (€)', border: OutlineInputBorder()),
            onChanged: (_) => apply(),
          ),
        ),
        IconButton(onPressed: widget.onDelete, icon: const Icon(Icons.delete_outline)),
      ]),
    );
  }
}

/* =======================
  WIZARD
  ======================= */
class OrderWizard extends StatefulWidget {
  final Product product;
  final Map<String, List<OptionItem>>? initialPicked;
  final String? initialNote;
  final bool editMode;
  const OrderWizard({
    super.key,
    required this.product,
    this.initialPicked,
    this.initialNote,
    this.editMode = false,
  });
  @override
  State<OrderWizard> createState() => _OrderWizardState();
}
class _OrderWizardState extends State<OrderWizard> {
  int step = 0;
  final Map<String, List<OptionItem>> picked = {};
  final TextEditingController noteCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.initialPicked != null) {
      for (final e in widget.initialPicked!.entries) {
        picked[e.key] = List<OptionItem>.from(e.value);
      }
    }
    if (widget.initialNote != null) {
      noteCtrl.text = widget.initialNote!;
    }
  }

  bool _isTotoroSelected() {
    final l = picked['type_burger'];
    final id = (l == null || l.isEmpty) ? '' : l.first.id;
    return id == 'totoro';
  }
  
  double _sansFritesDedansPrice() {
    final l = picked['type_tacos'];
    final id = (l == null || l.isEmpty) ? '' : l.first.id;
    if (id == 't1') return 2.0;
    if (id == 't2') return 4.0;
    if (id == 't3') return 6.0;
    return 2.0;
  }
  List<OptionGroup> _groupsForVisibility(List<OptionGroup> base) {
    if (widget.product.name == 'Menu Enfant') {
      final cheese = (picked['choix_enfant'] ?? const <OptionItem>[]).any((it) => it.id == 'cheese_menu');
      return base.where((g) {
        if (g.id == 'crudites_enfant') return cheese;
        return true;
      }).toList();
    }
    if (widget.product.name == 'Tacos') {
      String sel(String gid) {
        final l = picked[gid];
        return (l == null || l.isEmpty) ? '' : l.first.id;
      }
      final t = sel('type_tacos');
      final filtered = base.where((g) {
        if (g.id == 'viande2') return t == 't2' || t == 't3';
        if (g.id == 'viande3') return t == 't3';
        return true;
      }).toList();
      for (int i = 0; i < filtered.length; i++) {
        final g = filtered[i];
        if (g.id == 'supp_tacos') {
          final price = _sansFritesDedansPrice();
          final items = [
            ...g.items.map((e) => OptionItem(id: e.id, label: e.label, price: e.price)),
            OptionItem(id: 'sans_frites_dedans', label: 'Sans frites dans tacos', price: price),
          ];
          filtered[i] = OptionGroup(
            id: g.id, title: g.title, multiple: g.multiple, minSelect: g.minSelect, maxSelect: g.maxSelect, items: items,
          );
          final selList = picked['supp_tacos'];
          if (selList != null) {
            for (final it in selList) {
              if (it.id == 'sans_frites_dedans' && it.price != price) {
                it.price = price;
              }
            }
          }
          break;
        }
      }
      return filtered;
    }
    // TOTORO SEÇİLDİYSE SOS EKRANINI TAMAMEN SİL, ATLA
    if (widget.product.name == 'Burgers') {
      if (_isTotoroSelected()) {
        return base.where((g) => g.id != 'sauce_burger').toList();
      }
    }
    return base;
  }

  void _toggleSingle(OptionGroup g, OptionItem it) {
    picked[g.id] = [it];
    setState(() {});
  }

  // TÜM KISITLAMALAR KALDIRILDI - TAMAMEN ÖZGÜR SEÇİM MANTIĞI
  void _toggleMulti(OptionGroup g, OptionItem it) {
    final list = List<OptionItem>.from(picked[g.id] ?? []);
    bool exists = list.any((e) => e.id == it.id);
    
    if (exists) {
      // Eğer seçiliyse kaldır
      list.removeWhere((e) => e.id == it.id);
    } else {
      // Değilse direkt ekle
      list.add(it);
    }
    
    picked[g.id] = list;
    setState(() {});
  }

  bool _validGroup(OptionGroup g) {
    final n = (picked[g.id] ?? const []).length;
    if (g.multiple) return n >= g.minSelect;
    return n >= g.minSelect && n <= g.maxSelect;
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groupsForVisibility(widget.product.groups);
    final isSummary = step >= groups.length;
    final total = widget.product.priceForSelection(picked);
    void goPrev() {
      if (isSummary) {
        setState(() => step = groups.isEmpty ? 0 : groups.length - 1);
      } else if (step > 0) {
        setState(() => step--);
      } else {
        Navigator.pop(context);
      }
    }
    Future<void> goNext() async {
      if (isSummary) {
        if (widget.editMode) {
          final result = {for (final e in picked.entries) e.key: List<OptionItem>.from(e.value)};
          Navigator.pop(context, {'picked': result, 'note': noteCtrl.text.trim()});
        } else {
          final app = AppScope.of(context);
          app.addLineToCart(widget.product, picked, note: noteCtrl.text.trim());
          if (!mounted) return;
          Navigator.pop(context, true);
        }
        return;
      }
      final g = groups[step];
      if (!_validGroup(g)) {
        _showWarn(context, 'Sélection invalide pour "${g.title}".');
        return;
      }
      setState(() => step++);
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(isSummary ? 'Récapitulatif' : widget.product.name),
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: goPrev),
      ),
      body: isSummary
          ? _Summary(product: widget.product, picked: picked, total: total, noteCtrl: noteCtrl)
          : _GroupStep(
              group: groups[step],
              picked: picked,
              toggleSingle: _toggleSingle,
              toggleMulti: _toggleMulti,
            ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.tonal(
                  onPressed: goPrev,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 14),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.arrow_back),
                        SizedBox(width: 8),
                        Text('Retour'),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: goNext,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(isSummary
                            ? (widget.editMode ? Icons.check : Icons.add_shopping_cart)
                            : Icons.arrow_forward),
                        const SizedBox(width: 8),
                        Text(isSummary ? (widget.editMode ? 'Enregistrer' : 'Ajouter au panier') : 'Suivant'),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GroupStep extends StatelessWidget {
  final OptionGroup group;
  final Map<String, List<OptionItem>> picked;
  final void Function(OptionGroup, OptionItem) toggleSingle;
  final void Function(OptionGroup, OptionItem) toggleMulti;
  const _GroupStep({
    required this.group, required this.picked, required this.toggleSingle, required this.toggleMulti,
  });
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Text(
            group.title + (group.multiple ? (group.minSelect > 0 ? '  (min ${group.minSelect})' : '') : ''),
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ),
        Expanded(
          child: Builder(
            builder: (context) {
              final bottomSafe = MediaQuery.of(context).padding.bottom;
              final bottomBarH = kBottomNavigationBarHeight;
              final gridBottomPad = 12.0 + bottomSafe + bottomBarH;
              return GridView.builder(
                padding: EdgeInsets.fromLTRB(12, 8, 12, gridBottomPad),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 140, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 0.90,
                ),
                itemCount: group.items.length,
                itemBuilder: (_, i) {
                  final it = group.items[i];
                  final selectedList = picked[group.id] ?? const <OptionItem>[];
                  final isSelected = selectedList.any((e) => e.id == it.id);
                  final color = Theme.of(context).colorScheme;
                  
                  void onTap() {
                    if (group.multiple) {
                      toggleMulti(group, it);
                    } else {
                      toggleSingle(group, it);
                    }
                  }
                  
                  // KISITLAMALAR VE OPACITY KALDIRILDI
                  return InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: onTap,
                    child: Ink(
                      decoration: BoxDecoration(
                        color: isSelected ? color.primaryContainer : color.surfaceVariant,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: isSelected ? color.primary : color.outlineVariant,
                          width: isSelected ? 2 : 1,
                        ),
                      ),
                      child: Stack(
                        children: [
                          Positioned(
                            top: 6, right: 6,
                            child: group.multiple
                                ? Icon(
                                    isSelected ? Icons.check_box : Icons.check_box_outline_blank,
                                    size: 18, color: isSelected ? color.primary : color.onSurfaceVariant,
                                  )
                                : Icon(
                                    isSelected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                                    size: 18, color: isSelected ? color.primary : color.onSurfaceVariant,
                                  ),
                          ),
                          Center(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    it.label,
                                    textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                                  ),
                                  const SizedBox(height: 4),
                                  if (it.price != 0)
                                    Text(
                                      '+ ${_formatEuro(it.price)}',
                                      style: TextStyle(fontSize: 12, color: color.onSurfaceVariant),
                                      textAlign: TextAlign.center,
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Summary extends StatelessWidget {
  final Product product;
  final Map<String, List<OptionItem>> picked;
  final double total;
  final TextEditingController noteCtrl;

  const _Summary({required this.product, required this.picked, required this.total, required this.noteCtrl});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text('Récapitulatif — ${product.name}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        for (final g in product.groups)
          if ((picked[g.id] ?? const <OptionItem>[]).isNotEmpty) ...[
            Text(g.title, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            for (final it in (picked[g.id] ?? const <OptionItem>[]))
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text('• ${it.label}'),
                Text(it.price == 0 ? '€0.00' : '€${it.price.toStringAsFixed(2)}'),
              ]),
            const SizedBox(height: 8),
            const Divider(),
          ],
        
        const SizedBox(height: 8),
        TextField(
          controller: noteCtrl,
          maxLines: 2,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Note pour la cuisine (ex: sans sel, allergie...)',
            alignLabelWithHint: true,
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.edit_note),
          ),
        ),
        const SizedBox(height: 16),
        
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Text('SOUS-TOTAL', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          Text('€${total.toStringAsFixed(2)}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        ]),
        const SizedBox(height: 24),
      ],
    );
  }
}

/* =======================
  PAGE 3 : PANIER
  ======================= */
class CartPage extends StatelessWidget {
  const CartPage({super.key});
  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final lines = app.cart;
    final total = lines.fold(0.0, (s, l) => s + l.total);
    if (lines.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: const [
          Icon(Icons.shopping_bag_outlined, size: 48),
          SizedBox(height: 8),
          Text('Panier vide. Ajoutez des produits.'),
        ]),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Row(children: [
            const Text('Panier', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const Spacer(),
            TextButton.icon(
              onPressed: () => app.clearCart(),
              icon: const Icon(Icons.delete_sweep),
              label: const Text('Vider'),
            ),
          ]),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: lines.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final l = lines[i];
              return ListTile(
                leading: const Icon(Icons.fastfood),
                title: Text(
                  (l.qty > 1)
                      ? '${l.product.name} x${l.qty} • €${l.total.toStringAsFixed(2)}'
                      : '${l.product.name} • €${l.total.toStringAsFixed(2)}',
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final g in l.product.groups)
                      if ((l.picked[g.id] ?? const <OptionItem>[]).isNotEmpty) ...[
                        Text(g.title, style: const TextStyle(fontWeight: FontWeight.bold)),
                        for (final it in (l.picked[g.id] ?? const <OptionItem>[]))
                          Text('• ${it.label}${it.price == 0 ? '' : ' (+€${it.price.toStringAsFixed(2)})'}'),
                      ],
                    if (l.note.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          'Note: ${l.note}', 
                          style: TextStyle(color: Colors.red.shade700, fontWeight: FontWeight.bold),
                        ),
                      ),
                  ],
                ),
                trailing: Wrap(
                  spacing: 4,
                  children: [
                    IconButton(
                      tooltip: 'Diminuer',
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: () => app.updateCartLineQty(i, l.qty - 1),
                    ),
                    Text('${l.qty}', style: const TextStyle(fontWeight: FontWeight.bold)),
                    IconButton(
                      tooltip: 'Augmenter',
                      icon: const Icon(Icons.add_circle_outline),
                      onPressed: () => app.updateCartLineQty(i, l.qty + 1),
                    ),
                    IconButton(
                      tooltip: 'Modifier',
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () async {
                        final result = await Navigator.push<Map<String, dynamic>>(
                          context,
                          MaterialPageRoute(
                            builder: (_) => OrderWizard(
                              product: l.product,
                              initialPicked: l.picked,
                              initialNote: l.note,
                              editMode: true,
                            ),
                          ),
                        );
                        if (result != null) {
                          app.updateCartLineAt(i, result['picked'], result['note']);
                          if (context.mounted) {
                            _snack(context, 'Ligne mise à jour.');
                          }
                        }
                      },
                    ),
                    IconButton(
                      tooltip: 'Supprimer',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => app.removeCartLineAt(i),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            const Text('TOTAL', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            Text('€${total.toStringAsFixed(2)}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: FilledButton.icon(
            onPressed: () async {
              final name = await _askCustomerName(context);
              if (name == null) return;
              final readyAt = await _askReadyTime(context);
              if (readyAt == null) return;
              final app = AppScope.of(context);
              final order = app.finalizeCartToOrder(customer: name, readyAtOverride: readyAt);
              if (order == null) return;
              try {
                await printOrderAndroidWith(order, app.printerIp, app.printerPort);
                if (context.mounted) {
                  _snack(context, 'Commande validée et envoyée à l’imprimante.');
                }
              } catch (e) {
                if (context.mounted) {
                  _snack(context, 'Commande enregistrée, mais impression échouée: $e');
                }
              }
            },
            icon: const Icon(Icons.check),
            label: const Text('Valider la commande'),
          ),
        ),
      ],
    );
  }
}

/* =======================
  PAGE 4 : COMMANDES (GÜNCELLENDİ: GÜNLÜK TAKİP EKRANI)
  ======================= */
class OrdersPage extends StatelessWidget {
  const OrdersPage({super.key});
  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final allOrders = app.orders.reversed.toList();
    
    if (allOrders.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: const [
          Icon(Icons.receipt_long, size: 48),
          SizedBox(height: 8),
          Text('Aucune commande.'),
        ]),
      );
    }

    // Siparişleri Günlere Göre Grupla
    final Map<String, List<SavedOrder>> grouped = {};
    for (var o in allOrders) {
      final dateStr = '${_two(o.createdAt.day)}/${_two(o.createdAt.month)}/${o.createdAt.year}';
      grouped.putIfAbsent(dateStr, () => []).add(o);
    }

    // SADECE BUGÜNÜN İSTATİSTİKLERİ
    final now = DateTime.now();
    final todayStr = '${_two(now.day)}/${_two(now.month)}/${now.year}';
    final todaysOrders = grouped[todayStr] ?? [];
    
    final int totalOrdersToday = todaysOrders.length;
    final int totalItemsToday = todaysOrders.fold(0, (s, o) => s + o.lines.length);
    final double totalEurosToday = todaysOrders.fold(0.0, (s, o) => s + o.total);

    // Listeyi Widget'lara Çevir (Başlıklar ve Siparişler)
    final List<Widget> listItems = [];
    for (final entry in grouped.entries) {
      final dateStr = entry.key;
      final dayOrders = entry.value;
      final dayTotal = dayOrders.fold(0.0, (s, o) => s + o.total);

      // Günlük Başlık Kutusu (Tarih ve O Günün Toplam Cirosu)
      listItems.add(
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          color: Theme.of(context).colorScheme.primaryContainer,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                dateStr == todayStr ? "Aujourd'hui ($dateStr)" : dateStr,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),
              Text(
                'Total: €${dayTotal.toStringAsFixed(2)}',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),
            ],
          ),
        ),
      );

      // O Günün Siparişleri
      for (var o in dayOrders) {
        final who = o.customer.isEmpty ? '' : ' — ${o.customer}';
        listItems.add(
          ListTile(
            leading: const Icon(Icons.receipt),
            title: Text('Commande$who • ${o.lines.fold<int>(0, (s, l) => s + l.qty)} article(s) • €${o.total.toStringAsFixed(2)}'),
            subtitle: Text('Prêt à ${_two(o.readyAt.hour)}:${_two(o.readyAt.minute)}'),
            trailing: IconButton(
              icon: const Icon(Icons.print_outlined),
              onPressed: () async {
                try {
                  final app = AppScope.of(context);
                  await printOrderAndroidWith(o, app.printerIp, app.printerPort);
                  if (context.mounted) _snack(context, 'Envoyé à l’imprimante.');
                } catch (e) {
                  if (context.mounted) _snack(context, 'Échec de l’impression: $e');
                }
              },
              tooltip: 'Imprimer',
            ),
            onTap: () {
              showDialog(
                context: context,
                builder: (_) {
                  return AlertDialog(
                    title: const Text('Détails de la commande'),
                    content: SizedBox(
                      width: 360,
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          if (o.customer.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text('Client: ${o.customer}', style: const TextStyle(fontWeight: FontWeight.bold)),
                            ),
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text('Prêt à: ${_two(o.readyAt.hour)}:${_two(o.readyAt.minute)}', style: const TextStyle(fontWeight: FontWeight.bold)),
                          ),
                          for (int idx = 0; idx < o.lines.length; idx++) ...[
                            Text('Article ${idx + 1}: ${o.lines[idx].product.name}', style: const TextStyle(fontWeight: FontWeight.bold)),
                            for (final g in o.lines[idx].product.groups)
                              if ((o.lines[idx].picked[g.id] ?? const <OptionItem>[]).isNotEmpty) ...[
                                Text(g.title, style: const TextStyle(fontWeight: FontWeight.bold)),
                                for (final it in (o.lines[idx].picked[g.id] ?? const <OptionItem>[]))
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text('• ${it.label}'),
                                      Text(it.price == 0 ? '€0.00' : '€${it.price.toStringAsFixed(2)}'),
                                    ],
                                  ),
                              ],
                            if (o.lines[idx].note.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 4, bottom: 4),
                                child: Text('Note: ${o.lines[idx].note}', style: TextStyle(color: Colors.red.shade700, fontWeight: FontWeight.bold)),
                              ),
                            const Divider(),
                          ],
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('TOTAL', style: TextStyle(fontWeight: FontWeight.bold)),
                              Text('€${o.total.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ],
                      ),
                    ),
                    actions: [
                      TextButton.icon(
                        onPressed: () async {
                          try {
                            final app = AppScope.of(context);
                            await printOrderAndroidWith(o, app.printerIp, app.printerPort);
                            if (context.mounted) {
                              Navigator.pop(context);
                              _snack(context, 'Envoyé à l’imprimante.');
                            }
                          } catch (e) {
                            _snack(context, 'Échec de l’impression: $e');
                          }
                        },
                        icon: const Icon(Icons.print_outlined),
                        label: const Text('Imprimer'),
                      ),
                      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Fermer')),
                    ],
                  );
                },
              );
            },
          ),
        );
        listItems.add(const Divider(height: 1));
      }
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Row(children: [
            const Text('Commandes', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const Spacer(),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: () async {
                final pinOk = await _askPin(context);
                if (!pinOk) return;
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text('Tout supprimer ?'),
                    content: const Text('Toutes les commandes seront supprimées de l\'historique. Action irréversible.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
                      FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Supprimer')),
                    ],
                  ),
                );
                if (ok == true) app.clearOrders();
              },
              icon: const Icon(Icons.delete_forever),
              label: const Text('Tout vider'),
            ),
          ]),
        ),
        // YENİ: SADECE BUGÜNÜN İSTATİSTİKLERİ KARTİ
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Card(
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("Statistiques d'Aujourd'hui", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _Stat(label: 'Commandes', value: '$totalOrdersToday'),
                      _Stat(label: 'Articles', value: '$totalItemsToday'),
                      _Stat(label: 'Caisse', value: '€${totalEurosToday.toStringAsFixed(2)}'),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        const Divider(height: 1),
        // SİPARİŞLERİN GÜNLERE GÖRE LİSTELENMESİ
        Expanded(
          child: ListView.builder(
            itemCount: listItems.length,
            itemBuilder: (context, index) {
              return listItems[index];
            },
          ),
        ),
      ],
    );
  }
}

/* =======================
  DİYALOGLAR & UTIL
  ======================= */
Future<bool> _askPin(BuildContext context) async {
  final ctrl = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Code PIN requis'),
      content: TextField(
        controller: ctrl,
        keyboardType: TextInputType.number,
        obscureText: true,
        maxLength: 8,
        decoration: const InputDecoration(labelText: 'Entrez le code', border: OutlineInputBorder()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim() == _ADMIN_PIN), child: const Text('Valider')),
      ],
    ),
  );
  if (ok != true && context.mounted) _snack(context, 'Code incorrect.');
  return ok == true;
}

Future<String?> _askCustomerName(BuildContext context) async {
  final ctrl = TextEditingController();
  String? error;
  return showDialog<String>(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(builder: (ctx, setState) {
        return AlertDialog(
          title: const Text('Nom du client'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ctrl,
                autofocus: true,
                decoration: InputDecoration(labelText: 'Écrire le nom', border: const OutlineInputBorder(), errorText: error),
                onSubmitted: (_) {
                  if (ctrl.text.trim().isEmpty) {
                    setState(() => error = 'Le nom est requis.');
                  } else {
                    Navigator.pop(ctx, ctrl.text.trim());
                  }
                },
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, null), child: const Text('Annuler')),
            FilledButton(
              onPressed: () {
                final name = ctrl.text.trim();
                if (name.isEmpty) {
                  setState(() => error = 'Le nom est requis.');
                  return;
                }
                Navigator.pop(ctx, name);
              },
              child: const Text('Valider'),
            ),
          ],
        );
      });
    },
  );
}

Future<DateTime?> _askReadyTime(BuildContext context) async {
  final app = AppScope.of(context);
  final now = DateTime.now();
  final anchor = DateTime(now.year, now.month, now.day, now.hour, now.minute);
  
  final defaultDT = anchor.add(Duration(minutes: app.prepMinutes));
  final earliestDT = anchor; 
  
  TimeOfDay initial = TimeOfDay(hour: defaultDT.hour, minute: defaultDT.minute);
  
  while (true) {
    final picked = await showTimePicker(
      context: context,
      initialTime: initial,
      initialEntryMode: TimePickerEntryMode.input,
      helpText: 'Heure de retrait (au plus tôt ${_two(earliestDT.hour)}:${_two(earliestDT.minute)})',
      builder: (ctx, child) {
        return MediaQuery(
          data: MediaQuery.of(ctx!).copyWith(alwaysUse24HourFormat: true),
          child: child!,
        );
      },
    );
    if (picked == null) return null;
    
    DateTime pickedDT = DateTime(anchor.year, anchor.month, anchor.day, picked.hour, picked.minute);
    
    if (picked.hour < anchor.hour - 12) {
      pickedDT = pickedDT.add(const Duration(days: 1));
    }

    if (pickedDT.isBefore(earliestDT)) {
      if (context.mounted) {
        _snack(context, 'Vous ne pouvez pas choisir avant ${_two(earliestDT.hour)}:${_two(earliestDT.minute)}.', ms: 1800);
      }
      initial = TimeOfDay(hour: earliestDT.hour, minute: earliestDT.minute);
      continue;
    }
    return pickedDT;
  }
}

void _snack(BuildContext context, String msg, {int ms = 1200}) {
  if (!context.mounted) return;
  final bottomInset = MediaQuery.of(context).padding.bottom;
  final bottomBar = kBottomNavigationBarHeight;
  final bottomMargin = 12 + bottomInset + bottomBar;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: Duration(milliseconds: ms),
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.fromLTRB(12, 0, 12, bottomMargin),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        dismissDirection: DismissDirection.horizontal,
      ),
    );
}
void _showWarn(BuildContext context, String msg) {
  _snack(context, msg);
}

// ==================================================
// ESCP/RAW yazdırma yardımcıları
// ==================================================
String _two(int n) => n.toString().padLeft(2, '0');
String _formatEuro(double v) => '€${v.toStringAsFixed(2)}';
String _money(double v) => '${v.toStringAsFixed(2).replaceAll('.', ',')} €';
String _rightLine(String left, String right, {int width = 32}) {
  left = left.replaceAll('\n', ' ');
  right = right.replaceAll('\n', ' ');
  if (left.length + right.length > width) {
    left = left.substring(0, width - right.length);
  }
  return left + ' ' * (width - left.length - right.length) + right;
}

String _shortLabel(CartLine l) {
  String base = l.product.name;
  String extra = '';
  String firstLabelOf(String gid) {
    final list = l.picked[gid];
    if (list == null || list.isEmpty) return '';
    return list.first.label;
  }
  if (base == 'Tacos') {
    extra = firstLabelOf('type_tacos');
  } else if (base == 'Burgers') {
    final b = firstLabelOf('type_burger');
    if (b.isNotEmpty) base = b;
  } else if (base == 'Sandwich') {
    extra = firstLabelOf('type_sand');
  } else if (base == 'Menu Enfant') {
    extra = firstLabelOf('choix_enfant');
  }
  final label = (extra.isNotEmpty) ? '$base ${extra.toLowerCase()}' : base;
  return label;
}

void _cmd(Socket s, List<int> bytes) => s.add(bytes);
void _boldOn(Socket s) => _cmd(s, [27, 69, 1]);
void _boldOff(Socket s) => _cmd(s, [27, 69, 0]);
void _size(Socket s, int n) => _cmd(s, [29, 33, n]);
void _alignLeft(Socket s) => _cmd(s, [27, 97, 0]);
void _alignCenter(Socket s) => _cmd(s, [27, 97, 1]);
void _alignRight(Socket s) => _cmd(s, [27, 97, 2]);
void _strongLine(Socket s, String text) {
  _boldOn(s);
  _size(s, 1);
  _writeCp1252(s, text.toUpperCase() + '\n');
  _size(s, 0);
  _boldOff(s);
}
void _writeCp1252(Socket socket, String text) {
  final out = <int>[];
  for (final r in text.runes) {
    if (r == 0x20AC) {
      out.add(0x80);
      continue;
    }
    if (r <= 0x7F) {
      out.add(r);
      continue;
    }
    final ch = String.fromCharCode(r);
    const repl = {
      'ç': 'c', 'ğ': 'g', 'ı': 'i', 'ö': 'o', 'ş': 's', 'ü': 'u',
      'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
      'á': 'a', 'à': 'a', 'â': 'a', 'ä': 'a',
      'ô': 'o', 'ù': 'u', 'û': 'u', 'î': 'i', 'ï': 'i',
      'œ': 'oe',
      'Ç': 'C', 'Ğ': 'G', 'İ': 'I', 'Ö': 'O', 'Ş': 'S', 'Ü': 'U',
      'É': 'E', 'È': 'E', 'Ê': 'E', 'Ë': 'E',
      'Á': 'A', 'À': 'A', 'Â': 'A', 'Ä': 'A',
      'Ô': 'O', 'Ù': 'U', 'Û': 'U', 'Î': 'I', 'Ï': 'I',
      'Œ': 'OE',
      '–': '-', '—': '-', '…': '...',
    };
    final s = repl[ch] ?? '?';
    for (final cu in s.codeUnits) {
      if (cu == 0x20AC) {
        out.add(0x80);
      } else {
        out.add(cu <= 0x7F ? cu : 0x3F);
      }
    }
  }
  socket.add(out);
}
Future<void> printOrderAndroidWith(SavedOrder o, String ip, int port) async {
  final socket = await Socket.connect(ip, port, timeout: const Duration(seconds: 5));
  _cmd(socket, [27, 64]);
  _cmd(socket, [27, 116, 16]);
  _alignCenter(socket);
  _size(socket, 17);
  _boldOn(socket);
  _writeCp1252(socket, '*** BISCORNUE ***\n');
  _boldOff(socket);
  _size(socket, 0);
  if (o.customer.isNotEmpty) {
    _size(socket, 1);
    _boldOn(socket);
    _writeCp1252(socket, 'Client: ${o.customer}\n');
    _boldOff(socket);
    _size(socket, 0);
  }
  _boldOn(socket);
  _size(socket, 1);
  _writeCp1252(socket, 'Prêt à: ${_two(o.readyAt.hour)}:${_two(o.readyAt.minute)}\n');
  _size(socket, 0);
  _boldOff(socket);
  _alignLeft(socket);
  _writeCp1252(socket, '--------------------------------\n');
  for (int i = 0; i < o.lines.length; i++) {
    final l = o.lines[i];
    final base = _shortLabel(l);
    final lineLabel = (l.qty > 1) ? '${l.qty}x $base' : base;
    _strongLine(socket, _rightLine(lineLabel, _money(l.total)));
    for (final g in l.product.groups) {
      final sel = l.picked[g.id] ?? const <OptionItem>[];
      if (sel.isNotEmpty) {
        _writeCp1252(socket, '  ${g.title}:\n');
        for (final it in sel) {
          _strongLine(socket, '    * ${it.label}');
        }
      }
    }
    if (l.note.isNotEmpty) {
      _writeCp1252(socket, '\n');
      _strongLine(socket, '  >>> NOTE: ${l.note.toUpperCase()} <<<');
    }
    
    if (i != o.lines.length - 1) {
      _writeCp1252(socket, '--------------------------------\n');
    }
  }
  _writeCp1252(socket, '--------------------------------\n');
  _alignRight(socket);
  _boldOn(socket);
  _size(socket, 1);
  _writeCp1252(socket, _rightLine('TOTAL', '€${o.total.toStringAsFixed(2).replaceAll('.', ',')}') + '\n');
  _size(socket, 0);
  _boldOff(socket);
  _cmd(socket, [10, 10, 29, 86, 66, 0]);
  await socket.flush();
  await socket.close();
}
Future<void> printTestToPrinter(String ip, int port) async {
  final socket = await Socket.connect(ip, port, timeout: const Duration(seconds: 5));
  _cmd(socket, [27, 64]);
  _cmd(socket, [27, 116, 16]);
  _alignCenter(socket);
  _boldOn(socket);
  _size(socket, 1);
  _writeCp1252(socket, '*** TEST IMPRESSION ***\n');
  _boldOff(socket);
  _size(socket, 0);
  final now = DateTime.now();
  _writeCp1252(socket, 'BISCORNUE\n');
  _writeCp1252(socket, 'IP: $ip  Port: $port\n');
  _writeCp1252(socket, '${_two(now.day)}/${_two(now.month)}/${now.year} '
          '${_two(now.hour)}:${_two(now.minute)}\n');
  _writeCp1252(socket, '--------------------------------\n');
  _writeCp1252(socket, 'Si ceci est lisible, la connexion est OK.\n');
  _cmd(socket, [10, 10, 29, 86, 66, 0]);
  await socket.flush();
  await socket.close();
}
class _Stat extends StatelessWidget {
  final String label;
  final String value;
  const _Stat({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: color.onSurfaceVariant)),
        const SizedBox(height: 2),
        Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      ],
    );
  }
}
