/// Bancos que a Início reconhece pelo nome (logo em `assets/bancos/<logo>.png`).
/// O sync do Meu Banco não traz o id do conector, só o nome: o casamento é por nome normalizado.
typedef BancoConhecido = ({String id, String nome, String? logo, int cor, RegExp padrao});

RegExp _p(String s) => RegExp(s);

// Mercado Pago não tem logo livre no Wikimedia Commons: usa o selo com iniciais.
final List<BancoConhecido> mbBancosConhecidos = [
  (id: 'inter', nome: 'Banco Inter', logo: 'inter', cor: 0xFFFF7A00, padrao: _p(r'\binter\b')),
  (id: 'santander', nome: 'Santander', logo: 'santander', cor: 0xFFEC0000, padrao: _p(r'\bsantander\b')),
  (id: 'nubank', nome: 'Nubank', logo: 'nubank', cor: 0xFF820AD1, padrao: _p(r'\bnubank\b|\bnu pagamentos\b|\bnu financeira\b')),
  (id: 'itau', nome: 'Itaú', logo: 'itau', cor: 0xFF1B5393, padrao: _p(r'\bitau\b|\bitaucard\b')),
  (id: 'bradesco', nome: 'Bradesco', logo: 'bradesco', cor: 0xFFCC092F, padrao: _p(r'\bbradesco\b|\bbradescard\b')),
  (id: 'bb', nome: 'Banco do Brasil', logo: 'bb', cor: 0xFF0038A8, padrao: _p(r'\bbanco do brasil\b|\bbb\b|\bourocard\b')),
  (id: 'caixa', nome: 'Caixa', logo: 'caixa', cor: 0xFF005CA9, padrao: _p(r'\bcaixa\b')),
  (id: 'c6', nome: 'C6 Bank', logo: 'c6', cor: 0xFF242424, padrao: _p(r'\bc6\b')),
  (id: 'mercadopago', nome: 'Mercado Pago', logo: null, cor: 0xFF009EE3, padrao: _p(r'\bmercado ?pago\b')),
  (id: 'picpay', nome: 'PicPay', logo: 'picpay', cor: 0xFF11C76F, padrao: _p(r'\bpicpay\b')),
  (id: 'xp', nome: 'XP', logo: 'xp', cor: 0xFF111111, padrao: _p(r'\bxp\b')),
  (id: 'btg', nome: 'BTG Pactual', logo: 'btg', cor: 0xFF001E62, padrao: _p(r'\bbtg\b')),
];

/// Minúsculas, sem acento nem pontuação ("Itaú Unibanco S.A." vira "itau unibanco s a").
String mbNormalizarBanco(String s) {
  const de = 'áàâãäéèêëíìîïóòôõöúùûüç';
  const para = 'aaaaaeeeeiiiiooooouuuuc';
  final b = StringBuffer();
  for (final c in s.toLowerCase().split('')) {
    final i = de.indexOf(c);
    b.write(i >= 0 ? para[i] : c);
  }
  return b.toString().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
}

/// O banco da lista que casa com [nome]; null se não for nenhum.
BancoConhecido? mbBancoConhecido(String? nome) {
  if (nome == null) return null;
  final n = mbNormalizarBanco(nome);
  if (n.isEmpty) return null;
  for (final b in mbBancosConhecidos) {
    if (b.padrao.hasMatch(n)) return b;
  }
  return null;
}

/// "BANCO INTER ·69-6" vira "Banco Inter": sem o final da conta, sem "S.A.", com caixa de título.
String mbNomeDoBancoLimpo(String s) {
  final n = s
      .replaceFirst(RegExp(r'\s*·\s*[\d-]+$'), '')
      .replaceFirst(RegExp(r'\s*\(brasil\)', caseSensitive: false), '')
      .replaceFirst(RegExp(r'\s+S[./]?A\.?$', caseSensitive: false), '')
      .trim();
  if (n != n.toUpperCase()) return n;
  return n
      .toLowerCase()
      .split(' ')
      .map((p) => p.isEmpty ? p : p[0].toUpperCase() + p.substring(1))
      .join(' ');
}
