// Regra de gasto compartilhada entre o painel (public/index.html) e o Worker.
export const CATEGORIAS = {
  "Income": "Receitas", "Salary": "Salário", "Retirement": "Aposentadoria", "Entrepreneurial activities": "Atividade empresarial",
  "Government aid": "Auxílio do governo", "Non-recurring income": "Receita eventual", "Loans and financing": "Empréstimos e financiamentos",
  "Late payment and overdraft costs": "Juros de atraso e cheque especial", "Interests charged": "Juros cobrados", "Financing": "Financiamento",
  "Real estate financing": "Financiamento imobiliário", "Vehicle financing": "Financiamento de veículo", "Student loan": "Crédito estudantil",
  "Loans": "Empréstimos", "Investments": "Investimentos", "Automatic investment": "Investimento automático", "Fixed income": "Renda fixa",
  "Mutual funds": "Fundos de investimento", "Variable income": "Renda variável", "Margin": "Margem", "Proceeds interests and dividends": "Rendimentos e dividendos",
  "Pension": "Previdência", "Savings": "Poupança", "Same person transfer": "Transferência entre minhas contas", "Transfers": "Transferências",
  "Transfer - Bank Slip": "Transferência - boleto", "Transfer - Cash": "Transferência - dinheiro", "Transfer - Check": "Transferência - cheque",
  "Transfer - DOC": "Transferência - DOC", "Transfer - Foreign Exchange": "Transferência - câmbio", "Transfer - Internal": "Transferência interna",
  "Transfer - PIX": "Pix", "Transfer - TED": "TED", "Third party transfers": "Transferência para terceiros",
  "Third party transfer - Bank Slip": "Boleto para terceiros", "Third party transfer - Debit Card": "Débito para terceiros",
  "Third party transfer - DOC": "DOC para terceiros", "Third party transfer - PIX": "Pix para terceiros", "Third party transfer - TED": "TED para terceiros",
  "Credit card payment": "Pagamento de fatura", "Legal obligations": "Obrigações legais", "Blocked balances": "Saldo bloqueado", "Alimony": "Pensão alimentícia",
  "Services": "Serviços", "Telecommunications": "Telecomunicações", "Internet": "Internet", "Mobile": "Celular", "TV": "TV",
  "Education": "Educação", "Online courses": "Cursos online", "University": "Faculdade", "School": "Escola", "Kindergarten": "Creche",
  "Wellness and fitness": "Bem-estar e academia", "Gyms and fitness centers": "Academia", "Sports practice": "Esportes", "Wellness": "Bem-estar",
  "Tickets": "Ingressos", "Stadiums and arenas": "Estádios e arenas", "Landmarks and museums": "Museus e atrações", "Cinema, theater and concerts": "Cinema, teatro e shows",
  "Shopping": "Compras", "Online shopping": "Compras online", "Electronics": "Eletrônicos", "Pet supplies and vet": "Pet e veterinário",
  "Clothing": "Roupas", "Kids and toys": "Infantil e brinquedos", "Bookstore": "Livraria", "Sports goods": "Artigos esportivos", "Office supplies": "Papelaria",
  "Cashback": "Cashback", "Digital services": "Serviços digitais", "Gaming": "Jogos", "Video streaming": "Streaming de vídeo", "Music streaming": "Streaming de música",
  "Groceries": "Supermercado", "Food and drinks": "Alimentação", "Eating out": "Restaurantes", "Food delivery": "Delivery",
  "Travel": "Viagem", "Airport and airlines": "Aéreo", "Accommodation": "Hospedagem", "Mileage programs": "Programas de milhas", "Bus tickets": "Passagens de ônibus",
  "Donations": "Doações", "Gambling": "Apostas", "Lottery": "Loteria", "Online bet": "Apostas online",
  "Taxes": "Impostos", "Income taxes": "Imposto de renda", "Taxes on investments": "Impostos sobre investimentos", "Tax on financial operations": "IOF",
  "Bank fees": "Tarifas bancárias", "Account fees": "Tarifa de conta", "Wire transfer fees and ATM fees": "Tarifas de transferência e saque", "Credit card fees": "Tarifas do cartão",
  "Housing": "Moradia", "Rent": "Aluguel", "Utilities": "Contas da casa", "Water": "Água", "Electricity": "Energia", "Gas": "Gás", "Houseware": "Casa e utilidades",
  "Urban land and building tax": "IPTU", "Healthcare": "Saúde", "Dentist": "Dentista", "Pharmacy": "Farmácia", "Optometry": "Ótica",
  "Hospital clinics and labs": "Hospitais, clínicas e exames", "Transportation": "Transporte", "Taxi and ride-hailing": "Táxi e aplicativos",
  "Public transportation": "Transporte público", "Car rental": "Aluguel de carro", "Bicycle": "Bicicleta", "Automotive": "Automotivo",
  "Gas stations": "Combustível", "Parking": "Estacionamento", "Tolls and in vehicle payment": "Pedágio e tag", "Vehicle ownership taxes and fees": "IPVA e taxas do veículo",
  "Vehicle maintenance": "Manutenção do veículo", "Traffic tickets": "Multas de trânsito", "Insurance": "Seguros", "Life insurance": "Seguro de vida",
  "Home insurance": "Seguro residencial", "Health insurance": "Plano de saúde", "Vehicle insurance": "Seguro do veículo", "Leisure": "Lazer", "Other": "Outros",
};
export const traduzir = (c) => (c ? CATEGORIAS[c] || c : "Sem categoria");

// Não é gasto: pagamento de fatura, investimentos/poupança e transferência entre minhas contas.
export const CAT_FORA = /credit card payment|same person transfer|investment|fixed income|mutual funds|variable income|savings|pension|margin/i;
export const DESC_FORA = /pagamento (de |da )?fatura|pgto\.? ?fatura|pagamento recebido|aplica[cç][aã]o|resgate|\bcdb\b|\blci\b|\blca\b|poupan[cç]a|porquinho|tesouro direto/i;
export const regraAuto = (t) => CAT_FORA.test(t.category || "") || DESC_FORA.test(t.description || "");
// O ajuste feito no painel (gasto = 1 ou 0) vale mais que a regra automática, nos dois sentidos.
export const naoEhGasto = (t) => (t.ajuste_gasto == null ? regraAuto(t) : !t.ajuste_gasto);

// Valor que entra nos totais de gasto. Cartão: compra positiva, estorno negativo. Conta: só saída (amount < 0).
// Parcela futura (scheduled) fica fora: ela entra pelo valorParcela no ciclo em que cai.
const valorBruto = (t, cartao) => (cartao ? t.amount : t.amount < 0 ? -t.amount : 0);
export const valorGasto = (t, cartao) => (t.scheduled || naoEhGasto(t) ? 0 : valorBruto(t, cartao));
export const valorParcela = (t, cartao) => (!t.scheduled || naoEhGasto(t) ? 0 : valorBruto(t, cartao));
