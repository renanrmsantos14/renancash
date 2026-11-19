import 'package:budget/struct/mbSync/espelhoWs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('URI do WebSocket mantém o prefixo da base e não deixa "?" vazio', () {
    expect(mbUriWsEspelho('https://host/mb').toString(), 'wss://host/mb/api/espelho/ws');
    expect(mbUriWsEspelho('https://host/mb/').toString(), 'wss://host/mb/api/espelho/ws');
    expect(mbUriWsEspelho('https://host').toString(), 'wss://host/api/espelho/ws');
    expect(mbUriWsEspelho('http://localhost:8787').toString(), 'ws://localhost:8787/api/espelho/ws');
    expect(mbUriWsEspelho('https://host/mb').toString().contains('?'), isFalse);
  });
}
