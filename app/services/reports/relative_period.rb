# Único lugar que resolve um período relativo (offset em dias) pra datas
# de verdade — usado pelo agendamento recorrente de PDF do relatório
# (ScheduledAction action_type: 'send_report_pdf'). O payload guarda só
# `start_days_ago`/`end_days_ago`, nunca datas absolutas, porque o mesmo
# agendamento dispara de novo a cada recorrência e precisa "ontem até 3
# dias atrás" ser recalculado a cada envio, não reenviar as datas do
# primeiro disparo. `today:` só existe pra facilitar teste — todo caller
# de produção chama sem esse argumento, pegando a data real na hora do
# envio.
module Reports
  module RelativePeriod
    module_function

    def resolve(start_days_ago:, end_days_ago:, today: Date.current)
      {
        start: today - start_days_ago.to_i.days,
        end: today - end_days_ago.to_i.days
      }
    end
  end
end
