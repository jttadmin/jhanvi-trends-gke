package com.jhanvitrends.order;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.method;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.requestTo;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withServerError;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withStatus;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withSuccess;

import com.jhanvitrends.order.Dtos.CreateOrderRequest;
import com.jhanvitrends.order.Dtos.LineItem;
import com.jhanvitrends.order.Dtos.OrderEvent;
import com.jhanvitrends.order.Dtos.OrderResponse;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.http.HttpMethod;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.test.web.client.MockRestServiceServer;
import org.springframework.web.client.RestClient;

/**
 * Checkout saga unit tests: real OrderService, with inventory/payment HTTP mocked by MockRestServiceServer
 * and the repository/Kafka mocked by Mockito. Needs no database, broker or other service.
 */
class OrderServiceTest {

    private MockRestServiceServer inventory;
    private MockRestServiceServer payment;
    private OrderRepository repository;
    private KafkaTemplate<String, Object> kafka;
    private SimpleMeterRegistry meters;
    private OrderService service;

    @BeforeEach
    @SuppressWarnings("unchecked")
    void setUp() {
        RestClient.Builder inventoryBuilder = RestClient.builder().baseUrl("http://inventory");
        RestClient.Builder paymentBuilder = RestClient.builder().baseUrl("http://payment");
        inventory = MockRestServiceServer.bindTo(inventoryBuilder).build();
        payment = MockRestServiceServer.bindTo(paymentBuilder).build();
        repository = mock(OrderRepository.class);
        when(repository.save(any(OrderEntity.class))).thenAnswer(inv -> inv.getArgument(0));
        kafka = mock(KafkaTemplate.class);
        when(kafka.send(anyString(), anyString(), any())).thenReturn(CompletableFuture.completedFuture(null));
        meters = new SimpleMeterRegistry();
        service = new OrderService(repository, inventoryBuilder.build(), paymentBuilder.build(), kafka,
                "order-events", "INR", meters);
    }

    private static CreateOrderRequest request() {
        return new CreateOrderRequest("u-1", "asha@x.in", Map.of("city", "Bengaluru"), List.of(
                new LineItem(1, "Earbuds", new BigDecimal("3499.00"), 2),
                new LineItem(7, "Novel", new BigDecimal("299.50"), 1)));
    }

    private OrderEvent publishedEvent() {
        ArgumentCaptor<Object> event = ArgumentCaptor.forClass(Object.class);
        verify(kafka).send(eq("order-events"), anyString(), event.capture());
        return (OrderEvent) event.getValue();
    }

    @Test
    void happyPathReservesChargesSavesCommitsAndPublishes() {
        inventory.expect(requestTo("http://inventory/reservations")).andExpect(method(HttpMethod.POST)).andRespond(withSuccess());
        payment.expect(requestTo("http://payment/payments")).andRespond(
                withSuccess("{\"paymentId\":\"pay_1\",\"status\":\"captured\"}", MediaType.APPLICATION_JSON));
        inventory.expect(method(HttpMethod.POST)).andRespond(withSuccess()); // commit

        OrderResponse order = service.placeOrder(request());

        assertThat(order.status()).isEqualTo("CONFIRMED");
        assertThat(order.totalAmount()).isEqualByComparingTo("7297.50"); // 2 x 3499 + 299.50
        assertThat(order.paymentId()).isEqualTo("pay_1");
        assertThat(order.currency()).isEqualTo("INR");
        assertThat(order.items()).hasSize(2);
        assertThat(publishedEvent().type()).isEqualTo("order.placed");
        assertThat(publishedEvent().itemCount()).isEqualTo(3);
        assertThat(meters.counter("orders.placed").count()).isEqualTo(1.0);
        inventory.verify();
        payment.verify();
    }

    @Test
    void outOfStockIs409AndNothingElseHappens() {
        inventory.expect(requestTo("http://inventory/reservations")).andRespond(withStatus(HttpStatus.CONFLICT));

        assertThatThrownBy(() -> service.placeOrder(request()))
                .isInstanceOfSatisfying(ApiException.class, e -> assertThat(e.getStatus()).isEqualTo(HttpStatus.CONFLICT));
        payment.verify(); // no payment call was expected or made
        verify(repository, never()).save(any());
        assertThat(meters.counter("orders.failed", "reason", "out_of_stock").count()).isEqualTo(1.0);
    }

    @Test
    void inventoryDownIs503() {
        inventory.expect(requestTo("http://inventory/reservations")).andRespond(withServerError());

        assertThatThrownBy(() -> service.placeOrder(request()))
                .isInstanceOfSatisfying(ApiException.class,
                        e -> assertThat(e.getStatus()).isEqualTo(HttpStatus.SERVICE_UNAVAILABLE));
    }

    @Test
    void declinedPaymentReleasesStockSavesFailedOrderAndIs402() {
        inventory.expect(requestTo("http://inventory/reservations")).andRespond(withSuccess());
        payment.expect(requestTo("http://payment/payments")).andRespond(withStatus(HttpStatus.PAYMENT_REQUIRED));
        inventory.expect(method(HttpMethod.POST)).andRespond(withSuccess()); // release

        assertThatThrownBy(() -> service.placeOrder(request()))
                .isInstanceOfSatisfying(ApiException.class,
                        e -> assertThat(e.getStatus()).isEqualTo(HttpStatus.PAYMENT_REQUIRED));

        inventory.verify();
        ArgumentCaptor<OrderEntity> saved = ArgumentCaptor.forClass(OrderEntity.class);
        verify(repository).save(saved.capture());
        assertThat(saved.getValue().getStatus()).isEqualTo("PAYMENT_FAILED");
        assertThat(publishedEvent().type()).isEqualTo("order.failed");
    }

    @Test
    void paymentServiceErrorReleasesStockAndIs502() {
        inventory.expect(requestTo("http://inventory/reservations")).andRespond(withSuccess());
        payment.expect(requestTo("http://payment/payments")).andRespond(withStatus(HttpStatus.BAD_REQUEST));
        inventory.expect(method(HttpMethod.POST)).andRespond(withSuccess()); // release

        assertThatThrownBy(() -> service.placeOrder(request()))
                .isInstanceOfSatisfying(ApiException.class, e -> assertThat(e.getStatus()).isEqualTo(HttpStatus.BAD_GATEWAY));
        inventory.verify();
        verify(repository, never()).save(any());
    }

    @Test
    void kafkaFailureDoesNotFailCheckout() {
        when(kafka.send(anyString(), anyString(), any())).thenThrow(new IllegalStateException("broker down"));
        inventory.expect(requestTo("http://inventory/reservations")).andRespond(withSuccess());
        payment.expect(requestTo("http://payment/payments")).andRespond(
                withSuccess("{\"paymentId\":\"pay_2\",\"status\":\"captured\"}", MediaType.APPLICATION_JSON));
        inventory.expect(method(HttpMethod.POST)).andRespond(withSuccess()); // commit

        assertThat(service.placeOrder(request()).status()).isEqualTo("CONFIRMED");
        assertThat(meters.counter("orders.events.publish.failed").count()).isEqualTo(1.0);
    }

    @Test
    void byIdReturns404ForMalformedOrUnknownIds() {
        when(repository.findById(any(UUID.class))).thenReturn(Optional.empty());
        assertThatThrownBy(() -> service.byId("not-a-uuid"))
                .isInstanceOfSatisfying(ApiException.class, e -> assertThat(e.getStatus()).isEqualTo(HttpStatus.NOT_FOUND));
        assertThatThrownBy(() -> service.byId(UUID.randomUUID().toString()))
                .isInstanceOfSatisfying(ApiException.class, e -> assertThat(e.getStatus()).isEqualTo(HttpStatus.NOT_FOUND));
    }

    @Test
    void byIdAndListsMapEntitiesToResponses() {
        UUID id = UUID.randomUUID();
        OrderEntity entity = new OrderEntity(id, "u-1", new BigDecimal("10.00"), "INR", Map.of());
        entity.setStatus(OrderEntity.Status.CONFIRMED);
        entity.getItems().add(new OrderItemEntity(3, "Mug", new BigDecimal("5.00"), 2));
        when(repository.findById(id)).thenReturn(Optional.of(entity));
        when(repository.findTop50ByUserIdOrderByCreatedAtDesc("u-1")).thenReturn(List.of(entity));
        when(repository.findTop200ByOrderByCreatedAtDesc()).thenReturn(List.of(entity));

        OrderResponse r = service.byId(id.toString());
        assertThat(r.id()).isEqualTo(id.toString());
        assertThat(r.items()).singleElement().satisfies(i -> assertThat(i.quantity()).isEqualTo(2));
        assertThat(service.forUser("u-1")).hasSize(1);
        assertThat(service.recent()).hasSize(1);
    }
}
