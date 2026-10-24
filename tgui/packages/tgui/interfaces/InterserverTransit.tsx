import { Box, Button, NoticeBox, Section } from 'tgui-core/components';
import type { BooleanLike } from 'tgui-core/react';
import { useBackend } from '../backend';
import { Window } from '../layouts';

type Data = {
  status: string;
  station: string;
  destination: string;
  connected: BooleanLike;
  on_board: BooleanLike;
  remaining: number;
  timer_label: string;
  error: string | null;
  enabled: BooleanLike;
};

export function InterserverTransit() {
  const { act, data } = useBackend<Data>();
  return (
    <Window width={450} height={350}>
      <Window.Content>
        <Section title="Межстанционные пассажирские перевозки">
          <Box fontSize="20px" mb={1}>{data.status}</Box>
          <Box>Маршрут: {data.station} → {data.destination}</Box>
          <Box mb={1}>Диспетчерская: {data.connected ? 'на связи' : 'связь недоступна'}</Box>
          {!!data.remaining && <NoticeBox>{data.timer_label}: {data.remaining} с</NoticeBox>}
          {data.error && <NoticeBox danger>{data.error}</NoticeBox>}
          <Button
            fluid
            icon={data.on_board ? 'rocket' : 'bell'}
            disabled={!data.enabled}
            onClick={() => act(data.on_board ? 'depart' : 'call')}
          >
            {data.on_board ? 'Запросить отправление' : 'Вызвать шаттл к причалу'}
          </Button>
        </Section>
        <Section title="Пассажирам">
          <Box>До отправления разместите багаж и займите места. Не покидайте шаттл во время предполётной проверки и стыковки. Следуйте указаниям диспетчера.</Box>
        </Section>
      </Window.Content>
    </Window>
  );
}
