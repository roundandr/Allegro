module pipeline_reg #(
    parameter int W = 32
)(
    input  logic         clk,
    input  logic         rst_n,

    // upstream
    input  logic         in_valid,
    output logic         in_ready,
    input  logic [W-1:0] in_data,

    // downstream
    output logic         out_valid,
    input  logic         out_ready,
    output logic [W-1:0] out_data
);


  // 是否发生传输
    wire fire_in  = in_valid  && in_ready;
    wire fire_out = out_valid && out_ready;
    
    // buffer 空，或者下游本拍会取走
    assign in_ready = !out_valid || out_ready;
    
    // 寄存器
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            out_data  <= '0;
        end else begin
            // 写入新数据
            if (fire_in) begin
                out_valid <= 1'b1;
                out_data  <= in_data;
            end
            // 下游取走，但本拍没有新数据补进来
            else if (fire_out) begin
                out_valid <= 1'b0;
            end
            else begin
                out_valid <= out_valid;
                out_data  <= out_data;
            end
        end
    end
endmodule
