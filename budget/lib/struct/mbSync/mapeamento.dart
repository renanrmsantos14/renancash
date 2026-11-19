
// O valor 'cashew:' é contrato de sincronização com o Meu Banco (ids já gravados no servidor): não renomear.
const String prefixoLocal = 'cashew:';
String idDoPk(String pk) => prefixoLocal + pk;
String pkDoId(String id) =>
    id.startsWith(prefixoLocal) ? id.substring(prefixoLocal.length) : id;

class CatLocal {
  final String pk, nome;
  final bool receita;
  final String? cor, icone, paiPk;
  final int ordem;
  final DateTime? modificadoEm;
  const CatLocal({
    required this.pk,
    required this.nome,
    required this.receita,
    this.cor,
    this.icone,
    this.paiPk,
    this.ordem = 0,
    this.modificadoEm,
  });
}
